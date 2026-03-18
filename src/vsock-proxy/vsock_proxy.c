/*
 * vsock-proxy — QNX guest vsock proxy daemon
 *
 * Bridges local TCP connections to the host via virtio-vsock hardware,
 * bypassing QNX's io-sock limitation of not supporting AF_VSOCK.
 *
 * Architecture:
 *   traced_relay → TCP 127.0.0.1:LOCAL_PORT → vsock-proxy → virtio mmio → host
 *
 * The proxy:
 *   1. Maps the virtio-vsock mmio device
 *   2. Initializes virtqueues (rx, tx, event)
 *   3. Listens on local TCP port
 *   4. Bridges connections: local TCP ↔ virtio-vsock protocol
 *
 * Usage:
 *   vsock-proxy --local-port 20001 --host-port 20001 --mmio-addr 0x1c0c0000
 *
 * Then in the guest:
 *   PERFETTO_RELAY_SOCK_NAME=127.0.0.1:20001 traced_relay
 *
 * Build (QNX SDP 8.0):
 *   qcc -Vgcc_ntoaarch64le -o vsock-proxy vsock_proxy.c -lsocket -lpthread
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

/*
 * ---------- virtio-vsock protocol ----------
 * (Same as virtio_vsock.h but self-contained for standalone build)
 */

#define VIRTIO_VSOCK_OP_INVALID        0
#define VIRTIO_VSOCK_OP_REQUEST        1
#define VIRTIO_VSOCK_OP_RESPONSE       2
#define VIRTIO_VSOCK_OP_RST            3
#define VIRTIO_VSOCK_OP_SHUTDOWN       4
#define VIRTIO_VSOCK_OP_RW             5
#define VIRTIO_VSOCK_OP_CREDIT_UPDATE  6
#define VIRTIO_VSOCK_OP_CREDIT_REQUEST 7

#define VIRTIO_VSOCK_TYPE_STREAM       1
#define VMADDR_CID_HOST                2

#define VIRTIO_VSOCK_SHUTDOWN_RCV      1
#define VIRTIO_VSOCK_SHUTDOWN_SEND     2

struct virtio_vsock_hdr {
    uint64_t src_cid;
    uint64_t dst_cid;
    uint32_t src_port;
    uint32_t dst_port;
    uint32_t len;
    uint16_t type;
    uint16_t op;
    uint32_t flags;
    uint32_t buf_alloc;
    uint32_t fwd_cnt;
} __attribute__((packed));

/*
 * ---------- virtio mmio definitions ----------
 * See VIRTIO spec v1.2, section 4.2.2 (MMIO Device Register Layout)
 */

#define VIRTIO_MMIO_MAGIC          0x000
#define VIRTIO_MMIO_VERSION        0x004
#define VIRTIO_MMIO_DEVICE_ID      0x008
#define VIRTIO_MMIO_VENDOR_ID      0x00c
#define VIRTIO_MMIO_DEVICE_FEATURES 0x010
#define VIRTIO_MMIO_DEVICE_FEATURES_SEL 0x014
#define VIRTIO_MMIO_DRIVER_FEATURES 0x020
#define VIRTIO_MMIO_DRIVER_FEATURES_SEL 0x024
#define VIRTIO_MMIO_QUEUE_SEL      0x030
#define VIRTIO_MMIO_QUEUE_NUM_MAX  0x034
#define VIRTIO_MMIO_QUEUE_NUM      0x038
#define VIRTIO_MMIO_QUEUE_READY    0x044
#define VIRTIO_MMIO_QUEUE_NOTIFY   0x050
#define VIRTIO_MMIO_INTERRUPT_STATUS 0x060
#define VIRTIO_MMIO_INTERRUPT_ACK  0x064
#define VIRTIO_MMIO_STATUS         0x070
#define VIRTIO_MMIO_QUEUE_DESC_LOW  0x080
#define VIRTIO_MMIO_QUEUE_DESC_HIGH 0x084
#define VIRTIO_MMIO_QUEUE_DRIVER_LOW  0x090
#define VIRTIO_MMIO_QUEUE_DRIVER_HIGH 0x094
#define VIRTIO_MMIO_QUEUE_DEVICE_LOW  0x0a0
#define VIRTIO_MMIO_QUEUE_DEVICE_HIGH 0x0a4
#define VIRTIO_MMIO_CONFIG_GEN     0x0fc
#define VIRTIO_MMIO_CONFIG         0x100

#define VIRTIO_STATUS_ACKNOWLEDGE  1
#define VIRTIO_STATUS_DRIVER       2
#define VIRTIO_STATUS_FEATURES_OK  8
#define VIRTIO_STATUS_DRIVER_OK    4
#define VIRTIO_STATUS_FAILED       128

#define VIRTIO_F_VERSION_1         32

#define VRING_DESC_F_NEXT     1
#define VRING_DESC_F_WRITE    2

/* Virtqueue layout */
struct vring_desc {
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed));

struct vring_avail {
    uint16_t flags;
    uint16_t idx;
    uint16_t ring[];
} __attribute__((packed));

struct vring_used_elem {
    uint32_t id;
    uint32_t len;
} __attribute__((packed));

struct vring_used {
    uint16_t flags;
    uint16_t idx;
    struct vring_used_elem ring[];
} __attribute__((packed));

/*
 * ---------- Virtqueue management ----------
 */

#define VQ_SIZE        128
#define VQ_RX          0
#define VQ_TX          1
#define VQ_EVENT       2
#define NUM_VQS        3

#define BUF_SIZE       (64 * 1024)
#define DEFAULT_CREDIT (128 * 1024)

struct virtqueue {
    unsigned              num;          /* queue size */
    struct vring_desc    *desc;         /* descriptor table */
    struct vring_avail   *avail;        /* available ring */
    struct vring_used    *used;         /* used ring */
    uint16_t              free_head;    /* first free descriptor */
    uint16_t              last_used;    /* last processed used entry */
    uint16_t              num_free;     /* number of free descriptors */
    void                 *buffers[VQ_SIZE]; /* buffer pointers */
    uint64_t              buf_paddrs[VQ_SIZE]; /* buffer physical addresses */
    void                 *raw;          /* raw allocated memory */
    size_t                raw_size;
};

struct proxy_state {
    volatile uint32_t *mmio;        /* mmio base address */
    struct virtqueue   vqs[NUM_VQS];
    uint32_t           guest_cid;
    uint32_t           host_port;
    int                listen_fd;
    volatile int       running;

    /* Connection state */
    int                client_fd;     /* local TCP client */
    uint32_t           local_port;    /* our vsock source port */
    int                connected;     /* vsock connection established */

    /* Credit flow control */
    uint32_t           buf_alloc;     /* our buffer allocation */
    uint32_t           fwd_cnt;       /* bytes we've consumed */
    uint32_t           peer_buf_alloc;
    uint32_t           peer_fwd_cnt;
    uint32_t           tx_cnt;        /* bytes sent to peer */
};

/* MMIO register access */
static inline uint32_t mmio_read(volatile uint32_t *base, uint32_t off) {
    return *(volatile uint32_t *)((uint8_t *)base + off);
}
static inline void mmio_write(volatile uint32_t *base, uint32_t off, uint32_t val) {
    *(volatile uint32_t *)((uint8_t *)base + off) = val;
}

/*
 * Align value up to given alignment.
 */
static inline size_t align_up(size_t val, size_t align) {
    return (val + align - 1) & ~(align - 1);
}

/*
 * Allocate and initialize a virtqueue.
 * Returns 0 on success, -1 on failure.
 */
static int
vq_init(struct proxy_state *ps, int qidx, unsigned num)
{
    struct virtqueue *vq = &ps->vqs[qidx];
    vq->num = num;
    vq->last_used = 0;

    /* Calculate sizes */
    size_t desc_size = sizeof(struct vring_desc) * num;
    size_t avail_size = sizeof(struct vring_avail) + sizeof(uint16_t) * num;
    size_t used_size = sizeof(struct vring_used) + sizeof(struct vring_used_elem) * num;

    size_t total = align_up(desc_size + avail_size, 4096) + align_up(used_size, 4096);

    /* Allocate physically contiguous memory */
    vq->raw = mmap(NULL, total, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_ANON | MAP_PHYS, NOFD, 0);
    if (vq->raw == MAP_FAILED) {
        fprintf(stderr, "vq_init: mmap failed for queue %d: %s\n", qidx, strerror(errno));
        return -1;
    }
    vq->raw_size = total;
    memset(vq->raw, 0, total);

    /* Layout: desc | avail || (page-aligned) used */
    vq->desc = (struct vring_desc *)vq->raw;
    vq->avail = (struct vring_avail *)((uint8_t *)vq->raw + desc_size);
    vq->used = (struct vring_used *)((uint8_t *)vq->raw + align_up(desc_size + avail_size, 4096));

    /* Build free descriptor chain */
    vq->free_head = 0;
    vq->num_free = num;
    for (unsigned i = 0; i < num - 1; i++) {
        vq->desc[i].next = i + 1;
        vq->desc[i].flags = VRING_DESC_F_NEXT;
    }
    vq->desc[num - 1].next = 0xFFFF;

    /* Allocate buffers for RX queue */
    if (qidx == VQ_RX) {
        for (unsigned i = 0; i < num; i++) {
            void *buf = mmap(NULL, BUF_SIZE, PROT_READ | PROT_WRITE,
                             MAP_SHARED | MAP_ANON | MAP_PHYS, NOFD, 0);
            if (buf == MAP_FAILED) {
                fprintf(stderr, "vq_init: buffer mmap failed: %s\n", strerror(errno));
                return -1;
            }
            vq->buffers[i] = buf;
            /* Get physical address for DMA */
            /* On QNX, MAP_PHYS gives us a physically contiguous region */
            /* The physical address equals the virtual address for MAP_PHYS */
            vq->buf_paddrs[i] = (uint64_t)(uintptr_t)buf;
        }
    }

    /* Tell device about this queue via MMIO */
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_SEL, qidx);
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_NUM, num);

    uint64_t desc_paddr = (uint64_t)(uintptr_t)vq->desc;
    uint64_t avail_paddr = (uint64_t)(uintptr_t)vq->avail;
    uint64_t used_paddr = (uint64_t)(uintptr_t)vq->used;

    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_DESC_LOW, (uint32_t)desc_paddr);
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_DESC_HIGH, (uint32_t)(desc_paddr >> 32));
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_DRIVER_LOW, (uint32_t)avail_paddr);
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_DRIVER_HIGH, (uint32_t)(avail_paddr >> 32));
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_DEVICE_LOW, (uint32_t)used_paddr);
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_DEVICE_HIGH, (uint32_t)(used_paddr >> 32));
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_READY, 1);

    return 0;
}

/*
 * Post receive buffers on the RX queue.
 */
static void
vq_rx_post_buffers(struct proxy_state *ps)
{
    struct virtqueue *vq = &ps->vqs[VQ_RX];

    for (unsigned i = 0; i < vq->num && vq->num_free > 0; i++) {
        uint16_t idx = vq->free_head;
        if (idx == 0xFFFF) break;

        vq->free_head = vq->desc[idx].next;
        vq->num_free--;

        vq->desc[idx].addr = vq->buf_paddrs[idx];
        vq->desc[idx].len = BUF_SIZE;
        vq->desc[idx].flags = VRING_DESC_F_WRITE; /* device writes to this */
        vq->desc[idx].next = 0xFFFF;

        uint16_t avail_idx = vq->avail->idx % vq->num;
        vq->avail->ring[avail_idx] = idx;
        __sync_synchronize(); /* memory barrier */
        vq->avail->idx++;
    }

    /* Notify device */
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_NOTIFY, VQ_RX);
}

/*
 * Send a vsock packet via the TX virtqueue.
 */
static int
vsock_tx(struct proxy_state *ps, uint16_t op,
         const void *payload, uint32_t payload_len)
{
    struct virtqueue *vq = &ps->vqs[VQ_TX];

    if (vq->num_free < 1) {
        fprintf(stderr, "vsock_tx: no free descriptors\n");
        return -1;
    }

    /* Build header */
    struct virtio_vsock_hdr hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.src_cid = ps->guest_cid;
    hdr.dst_cid = VMADDR_CID_HOST;
    hdr.src_port = ps->local_port;
    hdr.dst_port = ps->host_port;
    hdr.len = payload_len;
    hdr.type = VIRTIO_VSOCK_TYPE_STREAM;
    hdr.op = op;
    hdr.buf_alloc = ps->buf_alloc;
    hdr.fwd_cnt = ps->fwd_cnt;

    /* Allocate a temporary buffer for header + payload */
    uint32_t total = sizeof(hdr) + payload_len;
    void *buf = mmap(NULL, align_up(total, 4096), PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_ANON | MAP_PHYS, NOFD, 0);
    if (buf == MAP_FAILED) return -1;

    memcpy(buf, &hdr, sizeof(hdr));
    if (payload && payload_len > 0) {
        memcpy((uint8_t *)buf + sizeof(hdr), payload, payload_len);
    }

    /* Set up descriptor */
    uint16_t idx = vq->free_head;
    vq->free_head = vq->desc[idx].next;
    vq->num_free--;

    vq->desc[idx].addr = (uint64_t)(uintptr_t)buf;
    vq->desc[idx].len = total;
    vq->desc[idx].flags = 0; /* device reads from this */
    vq->desc[idx].next = 0xFFFF;
    vq->buffers[idx] = buf;

    uint16_t avail_idx = vq->avail->idx % vq->num;
    vq->avail->ring[avail_idx] = idx;
    __sync_synchronize();
    vq->avail->idx++;

    /* Notify device */
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_NOTIFY, VQ_TX);

    return 0;
}

/*
 * Reclaim used TX descriptors.
 */
static void
vq_tx_reclaim(struct proxy_state *ps)
{
    struct virtqueue *vq = &ps->vqs[VQ_TX];

    while (vq->last_used != vq->used->idx) {
        uint16_t used_idx = vq->last_used % vq->num;
        uint32_t desc_idx = vq->used->ring[used_idx].id;

        /* Free the buffer */
        if (vq->buffers[desc_idx]) {
            munmap(vq->buffers[desc_idx], align_up(vq->desc[desc_idx].len, 4096));
            vq->buffers[desc_idx] = NULL;
        }

        /* Return descriptor to free list */
        vq->desc[desc_idx].next = vq->free_head;
        vq->desc[desc_idx].flags = VRING_DESC_F_NEXT;
        vq->free_head = desc_idx;
        vq->num_free++;

        vq->last_used++;
    }
}

/*
 * Process received vsock packets from the RX queue.
 */
static void
vq_rx_process(struct proxy_state *ps)
{
    struct virtqueue *vq = &ps->vqs[VQ_RX];

    while (vq->last_used != vq->used->idx) {
        uint16_t used_idx = vq->last_used % vq->num;
        uint32_t desc_idx = vq->used->ring[used_idx].id;
        uint32_t len = vq->used->ring[used_idx].len;

        void *buf = vq->buffers[desc_idx];
        if (buf && len >= sizeof(struct virtio_vsock_hdr)) {
            struct virtio_vsock_hdr *hdr = (struct virtio_vsock_hdr *)buf;
            uint32_t payload_len = len - sizeof(*hdr);
            void *payload = (uint8_t *)buf + sizeof(*hdr);

            switch (hdr->op) {
            case VIRTIO_VSOCK_OP_RESPONSE:
                /* Connection accepted by host */
                ps->connected = 1;
                ps->peer_buf_alloc = hdr->buf_alloc;
                ps->peer_fwd_cnt = hdr->fwd_cnt;
                printf("vsock-proxy: connected to host:%u\n", ps->host_port);
                break;

            case VIRTIO_VSOCK_OP_RW:
                /* Data from host → forward to local TCP client */
                if (ps->client_fd >= 0 && payload_len > 0) {
                    uint32_t sent = 0;
                    while (sent < payload_len) {
                        ssize_t n = send(ps->client_fd,
                                         (uint8_t *)payload + sent,
                                         payload_len - sent, 0);
                        if (n <= 0) break;
                        sent += (uint32_t)n;
                    }
                    ps->fwd_cnt += payload_len;

                    /* Send credit update if we've consumed significant data */
                    if (ps->fwd_cnt - ps->peer_fwd_cnt > ps->buf_alloc / 4) {
                        vsock_tx(ps, VIRTIO_VSOCK_OP_CREDIT_UPDATE, NULL, 0);
                    }
                }
                /* Update peer credit */
                ps->peer_buf_alloc = hdr->buf_alloc;
                ps->peer_fwd_cnt = hdr->fwd_cnt;
                break;

            case VIRTIO_VSOCK_OP_RST:
            case VIRTIO_VSOCK_OP_SHUTDOWN:
                printf("vsock-proxy: host closed connection (op=%u)\n", hdr->op);
                ps->connected = 0;
                if (ps->client_fd >= 0) {
                    close(ps->client_fd);
                    ps->client_fd = -1;
                }
                break;

            case VIRTIO_VSOCK_OP_CREDIT_UPDATE:
                ps->peer_buf_alloc = hdr->buf_alloc;
                ps->peer_fwd_cnt = hdr->fwd_cnt;
                break;

            case VIRTIO_VSOCK_OP_CREDIT_REQUEST:
                vsock_tx(ps, VIRTIO_VSOCK_OP_CREDIT_UPDATE, NULL, 0);
                break;

            default:
                printf("vsock-proxy: unknown op %u\n", hdr->op);
                break;
            }
        }

        /* Return descriptor to available ring */
        vq->desc[desc_idx].addr = vq->buf_paddrs[desc_idx];
        vq->desc[desc_idx].len = BUF_SIZE;
        vq->desc[desc_idx].flags = VRING_DESC_F_WRITE;
        vq->desc[desc_idx].next = 0xFFFF;

        uint16_t avail_idx = vq->avail->idx % vq->num;
        vq->avail->ring[avail_idx] = desc_idx;
        __sync_synchronize();
        vq->avail->idx++;

        vq->last_used++;
    }

    /* Notify device that we've posted new RX buffers */
    mmio_write(ps->mmio, VIRTIO_MMIO_QUEUE_NOTIFY, VQ_RX);
}

/*
 * Initialize the virtio-vsock device via MMIO.
 */
static int
virtio_init(struct proxy_state *ps, uint64_t mmio_addr, size_t mmio_size)
{
    /* Map MMIO region */
    ps->mmio = mmap(NULL, mmio_size, PROT_READ | PROT_WRITE | PROT_NOCACHE,
                    MAP_SHARED | MAP_PHYS, NOFD, (off_t)mmio_addr);
    if (ps->mmio == MAP_FAILED) {
        fprintf(stderr, "Failed to map MMIO at 0x%lx: %s\n",
                (unsigned long)mmio_addr, strerror(errno));
        return -1;
    }

    /* Verify magic and device ID */
    uint32_t magic = mmio_read(ps->mmio, VIRTIO_MMIO_MAGIC);
    uint32_t version = mmio_read(ps->mmio, VIRTIO_MMIO_VERSION);
    uint32_t device_id = mmio_read(ps->mmio, VIRTIO_MMIO_DEVICE_ID);

    if (magic != 0x74726976) { /* "virt" */
        fprintf(stderr, "Bad virtio magic: 0x%x (expected 0x74726976)\n", magic);
        return -1;
    }
    if (device_id != 19) {
        fprintf(stderr, "Not a vsock device: device_id=%u (expected 19)\n", device_id);
        return -1;
    }
    printf("vsock-proxy: virtio-vsock device v%u at 0x%lx\n",
           version, (unsigned long)mmio_addr);

    /* Device initialization sequence (VIRTIO spec 3.1.1) */
    mmio_write(ps->mmio, VIRTIO_MMIO_STATUS, 0); /* reset */
    mmio_write(ps->mmio, VIRTIO_MMIO_STATUS, VIRTIO_STATUS_ACKNOWLEDGE);
    mmio_write(ps->mmio, VIRTIO_MMIO_STATUS,
               VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER);

    /* Read features */
    mmio_write(ps->mmio, VIRTIO_MMIO_DEVICE_FEATURES_SEL, 1);
    uint32_t features_hi = mmio_read(ps->mmio, VIRTIO_MMIO_DEVICE_FEATURES);

    /* Accept VERSION_1 feature */
    mmio_write(ps->mmio, VIRTIO_MMIO_DRIVER_FEATURES_SEL, 1);
    mmio_write(ps->mmio, VIRTIO_MMIO_DRIVER_FEATURES,
               features_hi & (1u << (VIRTIO_F_VERSION_1 - 32)));
    mmio_write(ps->mmio, VIRTIO_MMIO_DRIVER_FEATURES_SEL, 0);
    mmio_write(ps->mmio, VIRTIO_MMIO_DRIVER_FEATURES, 0);

    mmio_write(ps->mmio, VIRTIO_MMIO_STATUS,
               VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER |
               VIRTIO_STATUS_FEATURES_OK);

    uint32_t status = mmio_read(ps->mmio, VIRTIO_MMIO_STATUS);
    if (!(status & VIRTIO_STATUS_FEATURES_OK)) {
        fprintf(stderr, "Device rejected features\n");
        mmio_write(ps->mmio, VIRTIO_MMIO_STATUS, VIRTIO_STATUS_FAILED);
        return -1;
    }

    /* Initialize virtqueues */
    for (int i = 0; i < NUM_VQS; i++) {
        if (vq_init(ps, i, VQ_SIZE) < 0) {
            fprintf(stderr, "Failed to init VQ %d\n", i);
            mmio_write(ps->mmio, VIRTIO_MMIO_STATUS, VIRTIO_STATUS_FAILED);
            return -1;
        }
    }

    /* Mark driver ready */
    mmio_write(ps->mmio, VIRTIO_MMIO_STATUS,
               VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER |
               VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK);

    /* Read guest CID from device config */
    ps->guest_cid = mmio_read(ps->mmio, VIRTIO_MMIO_CONFIG);
    printf("vsock-proxy: guest CID=%u\n", ps->guest_cid);

    /* Post receive buffers */
    vq_rx_post_buffers(ps);

    return 0;
}

/*
 * Main proxy loop: bridge local TCP ↔ virtio-vsock
 */
static void
proxy_loop(struct proxy_state *ps)
{
    uint8_t buf[BUF_SIZE];

    while (ps->running) {
        /* Accept local TCP connection */
        printf("vsock-proxy: waiting for connection on port %u...\n",
               ntohs(((struct sockaddr_in *)&(struct sockaddr_in){0})->sin_port));

        struct sockaddr_in client_addr;
        socklen_t addrlen = sizeof(client_addr);
        int client_fd = accept(ps->listen_fd,
                               (struct sockaddr *)&client_addr, &addrlen);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            break;
        }

        int flag = 1;
        setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
        ps->client_fd = client_fd;

        printf("vsock-proxy: local client connected, establishing vsock to host:%u\n",
               ps->host_port);

        /* Assign a local port (use client fd as port number) */
        ps->local_port = 50000 + (uint32_t)(client_fd % 10000);
        ps->connected = 0;
        ps->fwd_cnt = 0;
        ps->tx_cnt = 0;
        ps->buf_alloc = DEFAULT_CREDIT;

        /* Send vsock CONNECT request to host */
        if (vsock_tx(ps, VIRTIO_VSOCK_OP_REQUEST, NULL, 0) < 0) {
            fprintf(stderr, "vsock-proxy: failed to send connect request\n");
            close(client_fd);
            ps->client_fd = -1;
            continue;
        }

        /* Wait for RESPONSE with timeout */
        for (int i = 0; i < 30 && !ps->connected; i++) {
            usleep(100000); /* 100ms */
            /* Check for interrupt */
            uint32_t isr = mmio_read(ps->mmio, VIRTIO_MMIO_INTERRUPT_STATUS);
            if (isr) {
                mmio_write(ps->mmio, VIRTIO_MMIO_INTERRUPT_ACK, isr);
                vq_rx_process(ps);
                vq_tx_reclaim(ps);
            }
        }

        if (!ps->connected) {
            fprintf(stderr, "vsock-proxy: connection timeout\n");
            close(client_fd);
            ps->client_fd = -1;
            continue;
        }

        /* Bridge data between local TCP and virtio-vsock */
        while (ps->running && ps->connected && ps->client_fd >= 0) {
            struct pollfd fds[1];
            fds[0].fd = ps->client_fd;
            fds[0].events = POLLIN;

            int ret = poll(fds, 1, 50 /* 50ms timeout for checking virtio rx */);

            /* Always check for virtio interrupts */
            uint32_t isr = mmio_read(ps->mmio, VIRTIO_MMIO_INTERRUPT_STATUS);
            if (isr) {
                mmio_write(ps->mmio, VIRTIO_MMIO_INTERRUPT_ACK, isr);
                vq_rx_process(ps);
                vq_tx_reclaim(ps);
            }

            if (ret < 0) {
                if (errno == EINTR) continue;
                break;
            }

            /* Local TCP → virtio-vsock */
            if (ret > 0 && (fds[0].revents & POLLIN)) {
                /* Check credit */
                uint32_t credit = ps->peer_buf_alloc - (ps->tx_cnt - ps->peer_fwd_cnt);
                uint32_t max_read = (credit < sizeof(buf)) ? credit : sizeof(buf);

                if (max_read == 0) {
                    vsock_tx(ps, VIRTIO_VSOCK_OP_CREDIT_REQUEST, NULL, 0);
                    usleep(10000);
                    continue;
                }

                ssize_t n = recv(ps->client_fd, buf, max_read, 0);
                if (n > 0) {
                    vsock_tx(ps, VIRTIO_VSOCK_OP_RW, buf, (uint32_t)n);
                    ps->tx_cnt += (uint32_t)n;
                } else {
                    /* Client disconnected */
                    printf("vsock-proxy: local client disconnected\n");
                    vsock_tx(ps, VIRTIO_VSOCK_OP_SHUTDOWN, NULL, 0);
                    break;
                }
            }

            if (ret > 0 && (fds[0].revents & (POLLHUP | POLLERR))) {
                printf("vsock-proxy: local client error/hangup\n");
                vsock_tx(ps, VIRTIO_VSOCK_OP_SHUTDOWN, NULL, 0);
                break;
            }
        }

        /* Cleanup connection */
        if (ps->client_fd >= 0) {
            close(ps->client_fd);
            ps->client_fd = -1;
        }
        ps->connected = 0;
        printf("vsock-proxy: connection closed\n");
    }
}

static volatile int g_running = 1;

static void
sig_handler(int sig)
{
    (void)sig;
    g_running = 0;
}

static void
usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [options]\n"
            "\n"
            "Options:\n"
            "  --local-port PORT   Local TCP port to listen on (default: 20001)\n"
            "  --host-port PORT    Host vsock port to connect to (default: 20001)\n"
            "  --mmio-addr ADDR    virtio-vsock MMIO base address (default: 0x1c0c0000)\n"
            "  --mmio-size SIZE    MMIO region size (default: 0x1000)\n"
            "\n"
            "Example:\n"
            "  %s --local-port 20001 --host-port 20001\n"
            "  PERFETTO_RELAY_SOCK_NAME=127.0.0.1:20001 traced_relay\n",
            prog, prog);
}

int
main(int argc, char **argv)
{
    uint32_t local_port = 20001;
    uint32_t host_port = 20001;
    uint64_t mmio_addr = 0x1c0c0000;
    size_t   mmio_size = 0x1000;

    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--local-port") == 0 && i + 1 < argc) {
            local_port = (uint32_t)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--host-port") == 0 && i + 1 < argc) {
            host_port = (uint32_t)strtoul(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--mmio-addr") == 0 && i + 1 < argc) {
            mmio_addr = strtoull(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--mmio-size") == 0 && i + 1 < argc) {
            mmio_size = (size_t)strtoull(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }

    printf("vsock-proxy: local TCP :%u → vsock host:%u (mmio 0x%lx)\n",
           local_port, host_port, (unsigned long)mmio_addr);

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);
    signal(SIGPIPE, SIG_IGN);

    /* Initialize state */
    struct proxy_state ps;
    memset(&ps, 0, sizeof(ps));
    ps.host_port = host_port;
    ps.client_fd = -1;
    ps.buf_alloc = DEFAULT_CREDIT;
    ps.running = 1;

    /* Initialize virtio-vsock device */
    if (virtio_init(&ps, mmio_addr, mmio_size) < 0) {
        fprintf(stderr, "Failed to initialize virtio-vsock device\n");
        return 1;
    }

    /* Create listening TCP socket */
    ps.listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (ps.listen_fd < 0) {
        perror("socket");
        return 1;
    }

    int flag = 1;
    setsockopt(ps.listen_fd, SOL_SOCKET, SO_REUSEADDR, &flag, sizeof(flag));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)local_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(ps.listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(ps.listen_fd);
        return 1;
    }

    if (listen(ps.listen_fd, 4) < 0) {
        perror("listen");
        close(ps.listen_fd);
        return 1;
    }

    printf("vsock-proxy: listening on 127.0.0.1:%u\n", local_port);

    /* Run proxy */
    proxy_loop(&ps);

    /* Cleanup */
    close(ps.listen_fd);
    printf("vsock-proxy: exiting\n");
    return 0;
}
