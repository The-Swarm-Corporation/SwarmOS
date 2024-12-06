#!/bin/bash
# Integration script for SwarmOS Thread Manager
# This script sets up the thread management system as a core OS component

# Error handling with detailed messages
set -e
trap 'echo "Error occurred in integration script at line $LINENO. Exiting..."; exit 1' ERR

# Configuration
THREAD_MANAGER_DIR="core/thread-manager"
BUILD_DIR="custom-alpine-build"
CUSTOM_NAME="swarm-os"

echo "Starting thread manager integration..."

# Create the necessary directory structure
mkdir -p "${BUILD_DIR}/${THREAD_MANAGER_DIR}/src"
mkdir -p "${BUILD_DIR}/${THREAD_MANAGER_DIR}/scripts"

# Create the thread manager source file
cat > "${BUILD_DIR}/${THREAD_MANAGER_DIR}/src/thread_manager.c" << 'EOF'
/* Advanced Thread Swarm Monitor with Learning Capabilities
 * Continuously monitors, learns, and manages system threads
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/sysinfo.h>
#include <dirent.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <sched.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <sys/stat.h>

/* Enhanced data structures for thread monitoring and learning */
typedef struct {
    pid_t tid;
    unsigned long cpu_usage;
    unsigned long memory_usage;
    time_t last_active;
    unsigned long context_switches;
    double avg_cpu;
    double avg_memory;
    unsigned long lifetime;
    unsigned long anomaly_count;
    time_t create_time;
    int priority;
    char comm[256];  /* Command name */
} thread_info_t;

typedef struct {
    thread_info_t info;
    time_t timestamp;
} thread_history_entry_t;

typedef struct {
    double cpu_threshold;
    double memory_threshold;
    unsigned long context_switch_threshold;
    time_t inactivity_threshold;
} learning_parameters_t;

typedef struct {
    int agent_id;
    thread_info_t* monitored_threads;
    thread_history_entry_t* thread_history;
    int thread_count;
    int history_count;
    learning_parameters_t params;
    pthread_mutex_t lock;
} swarm_agent_t;

/* Global configuration */
#define MAX_AGENTS 8
#define MAX_THREADS_PER_AGENT 2000
#define MAX_HISTORY_PER_THREAD 1000
#define LEARNING_INTERVAL 60  /* seconds */
#define PERSISTENCE_FILE "/var/lib/swarm-monitor/thread_patterns.db"
#define LOG_FILE "/var/log/swarm-monitor.log"

/* Global state */
static swarm_agent_t agents[MAX_AGENTS];
static volatile int running = 1;
static pthread_mutex_t log_mutex = PTHREAD_MUTEX_INITIALIZER;

/* Enhanced logging function with timestamps */
void log_message(const char* format, ...) {
    va_list args;
    time_t now;
    char timestamp[64];
    FILE* log_file;
    
    pthread_mutex_lock(&log_mutex);
    
    time(&now);
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", localtime(&now));
    
    log_file = fopen(LOG_FILE, "a");
    if (log_file) {
        fprintf(log_file, "[%s] ", timestamp);
        va_start(args, format);
        vfprintf(log_file, format, args);
        va_end(args);
        fprintf(log_file, "\n");
        fclose(log_file);
    }
    
    pthread_mutex_unlock(&log_mutex);
}

/* Function to read detailed thread statistics */
static int read_thread_stats(pid_t tid, thread_info_t* info) {
    char path[256];
    char buffer[1024];
    FILE* fp;
    
    /* Read command name */
    snprintf(path, sizeof(path), "/proc/%d/comm", tid);
    fp = fopen(path, "r");
    if (fp) {
        if (fgets(info->comm, sizeof(info->comm), fp)) {
            info->comm[strcspn(info->comm, "\n")] = 0;
        }
        fclose(fp);
    }
    
    /* Read detailed statistics */
    snprintf(path, sizeof(path), "/proc/%d/stat", tid);
    fp = fopen(path, "r");
    if (!fp) {
        return -1;
    }

    if (fgets(buffer, sizeof(buffer), fp)) {
        unsigned long utime, stime, starttime;
        int priority;
        sscanf(buffer, "%*d %*s %*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %lu %lu %*d %*d %d %*d %*d %*d %lu",
               &utime, &stime, &priority, &starttime);
        
        info->cpu_usage = utime + stime;
        info->priority = priority;
        info->create_time = time(NULL) - (starttime / sysconf(_SC_CLK_TCK));
        info->lifetime = time(NULL) - info->create_time;
    }
    fclose(fp);

    /* Read memory information */
    snprintf(path, sizeof(path), "/proc/%d/status", tid);
    fp = fopen(path, "r");
    if (fp) {
        while (fgets(buffer, sizeof(buffer), fp)) {
            if (strncmp(buffer, "VmRSS:", 6) == 0) {
                sscanf(buffer, "VmRSS: %lu", &info->memory_usage);
            } else if (strncmp(buffer, "voluntary_ctxt_switches:", 23) == 0) {
                unsigned long voluntary, nonvoluntary;
                sscanf(buffer, "voluntary_ctxt_switches: %lu", &voluntary);
                if (fgets(buffer, sizeof(buffer), fp) && 
                    strncmp(buffer, "nonvoluntary_ctxt_switches:", 26) == 0) {
                    sscanf(buffer, "nonvoluntary_ctxt_switches: %lu", &nonvoluntary);
                    info->context_switches = voluntary + nonvoluntary;
                }
            }
        }
        fclose(fp);
    }

    info->last_active = time(NULL);
    return 0;
}

/* Function to update learning parameters based on historical data */
static void update_learning_parameters(swarm_agent_t* agent) {
    double total_cpu = 0, total_memory = 0;
    unsigned long total_switches = 0;
    int count = 0;
    
    for (int i = 0; i < agent->history_count; i++) {
        thread_info_t* info = &agent->thread_history[i].info;
        total_cpu += info->cpu_usage;
        total_memory += info->memory_usage;
        total_switches += info->context_switches;
        count++;
    }
    
    if (count > 0) {
        /* Update thresholds based on moving averages */
        agent->params.cpu_threshold = (total_cpu / count) * 2.0;
        agent->params.memory_threshold = (total_memory / count) * 2.0;
        agent->params.context_switch_threshold = (total_switches / count) * 1.5;
    }
}

/* Function to determine if a thread should be terminated */
static int should_terminate_thread(swarm_agent_t* agent, thread_info_t* info) {
    /* Check against learned thresholds */
    if (info->cpu_usage > agent->params.cpu_threshold &&
        info->memory_usage > agent->params.memory_threshold &&
        info->context_switches > agent->params.context_switch_threshold) {
        
        /* Additional checks for critical system threads */
        if (info->priority < 0 || strstr(info->comm, "systemd") ||
            strstr(info->comm, "init") || strstr(info->comm, "kthreadd")) {
            return 0;  /* Don't terminate critical system threads */
        }
        
        /* Check thread's history of anomalies */
        if (info->anomaly_count > 5) {
            log_message("Thread %d (%s) marked for termination - "
                       "Persistent anomalous behavior detected", 
                       info->tid, info->comm);
            return 1;
        }
    }
    
    /* Check for zombie threads */
    if (time(NULL) - info->last_active > agent->params.inactivity_threshold) {
        log_message("Thread %d (%s) marked for termination - "
                   "Inactive for %ld seconds",
                   info->tid, info->comm,
                   time(NULL) - info->last_active);
        return 1;
    }
    
    return 0;
}

/* Function to safely terminate a thread */
static void terminate_thread(pid_t tid) {
    /* First try SIGTERM for graceful shutdown */
    if (kill(tid, SIGTERM) == 0) {
        /* Give the thread a chance to cleanup */
        usleep(100000);  /* 100ms */
        
        /* Check if thread still exists */
        if (kill(tid, 0) == 0) {
            /* If still running, force termination */
            kill(tid, SIGKILL);
            log_message("Force terminated thread %d", tid);
        } else {
            log_message("Successfully terminated thread %d", tid);
        }
    }
}

/* Agent thread function with enhanced monitoring and learning */
static void* agent_monitor(void* arg) {
    swarm_agent_t* agent = (swarm_agent_t*)arg;
    DIR* proc_dir;
    struct dirent* entry;
    time_t last_learning_update = 0;
    
    /* Set high priority for monitoring thread */
    struct sched_param param;
    param.sched_priority = sched_get_priority_max(SCHED_FIFO);
    pthread_setschedparam(pthread_self(), SCHED_FIFO, &param);
    
    while (running) {
        proc_dir = opendir("/proc");
        if (!proc_dir) {
            usleep(1000000);  /* 1 second */
            continue;
        }

        pthread_mutex_lock(&agent->lock);
        
        /* Update learning parameters periodically */
        if (time(NULL) - last_learning_update > LEARNING_INTERVAL) {
            update_learning_parameters(agent);
            last_learning_update = time(NULL);
        }
        
        /* Scan and analyze threads */
        while ((entry = readdir(proc_dir)) != NULL) {
            pid_t tid;
            
            if (sscanf(entry->d_name, "%d", &tid) != 1) {
                continue;
            }
            
            thread_info_t thread_info = {.tid = tid};
            if (read_thread_stats(tid, &thread_info) == 0) {
                /* Store thread history */
                if (agent->history_count < MAX_HISTORY_PER_THREAD) {
                    agent->thread_history[agent->history_count].info = thread_info;
                    agent->thread_history[agent->history_count].timestamp = time(NULL);
                    agent->history_count++;
                }
                
                /* Check if thread should be terminated */
                if (should_terminate_thread(agent, &thread_info)) {
                    terminate_thread(tid);
                }
            }
        }
        
        pthread_mutex_unlock(&agent->lock);
        closedir(proc_dir);
        
        usleep(10000);  /* 10ms monitoring interval */
    }
    
    return NULL;
}

/* Initialize the enhanced swarm monitoring system */
int init_swarm_monitor(void) {
    pthread_t agent_threads[MAX_AGENTS];
    
    /* Create required directories */
    mkdir("/var/lib/swarm-monitor", 0755);
    
    /* Initialize agents with learning parameters */
    for (int i = 0; i < MAX_AGENTS; i++) {
        agents[i].agent_id = i;
        agents[i].monitored_threads = 
            calloc(MAX_THREADS_PER_AGENT, sizeof(thread_info_t));
        agents[i].thread_history = 
            calloc(MAX_HISTORY_PER_THREAD, sizeof(thread_history_entry_t));
        agents[i].thread_count = 0;
        agents[i].history_count = 0;
        
        /* Initialize learning parameters with default values */
        agents[i].params.cpu_threshold = 90.0;
        agents[i].params.memory_threshold = 1024 * 1024 * 100;  /* 100MB */
        agents[i].params.context_switch_threshold = 10000;
        agents[i].params.inactivity_threshold = 3600;  /* 1 hour */
        
        pthread_mutex_init(&agents[i].lock, NULL);
        
        if (pthread_create(&agent_threads[i], NULL, agent_monitor, &agents[i]) != 0) {
            log_message("Failed to create agent thread %d", i);
            return -1;
        }
    }
    
    log_message("Swarm monitor initialized with %d agents", MAX_AGENTS);
    return 0;
}

int main(void) {
    /* Set up signal handlers for clean shutdown */
    signal(SIGTERM, handle_shutdown);
    signal(SIGINT, handle_shutdown);
    
    /* Lock process in memory to prevent swapping */
    mlockall(MCL_CURRENT | MCL_FUTURE);
    
    log_message("Starting Enhanced Swarm Thread Monitor...");
    
    if (init_swarm_monitor() != 0) {
        log_message("Failed to initialize swarm monitor");
        return 1;
    }
    
    /* Main loop - keep the process running and handle any global tasks */
    while (running) {
        sleep(1);
    }
    
    return 0;
}
EOF

# Create the build script for the thread manager
cat > "${BUILD_DIR}/${THREAD_MANAGER_DIR}/scripts/build.sh" << 'EOF'
#!/bin/bash
set -e

# Compile the thread manager with optimizations
gcc -O2 -Wall -Wextra \
    -o thread_manager \
    src/thread_manager.c \
    -pthread \
    -ljson-c \
    -lsqlite3

# Install the binary
install -Dm755 thread_manager /usr/sbin/thread_manager
EOF

# Create the OpenRC service script
cat > "${BUILD_DIR}/${THREAD_MANAGER_DIR}/scripts/thread-manager.initd" << 'EOF'
#!/sbin/openrc-run

name="thread-manager"
description="SwarmOS Intelligent Thread Management System"
command="/usr/sbin/thread_manager"
command_args="${THREAD_MANAGER_OPTS}"
pidfile="/run/thread-manager.pid"

depend() {
    need net
    after boot
    before logger
}

start_pre() {
    # Ensure required directories exist
    checkpath -d -m 0755 -o root:root /var/lib/thread-manager
    checkpath -d -m 0755 -o root:root /var/log/thread-manager
}
EOF

# Create the APKBUILD file for packaging
cat > "${BUILD_DIR}/${THREAD_MANAGER_DIR}/APKBUILD" << 'EOF'
# Maintainer: SwarmOS Team
pkgname=swarm-thread-manager
pkgver=1.0.0
pkgrel=0
pkgdesc="Intelligent thread management system for SwarmOS"
url="https://swarmos.dev"
arch="all"
license="MIT"
depends="musl json-c sqlite"
makedepends="musl-dev gcc json-c-dev sqlite-dev"
install="$pkgname.pre-install $pkgname.post-install"
source="thread_manager.c"

build() {
    gcc -O2 -Wall -Wextra \
        -o thread_manager \
        "$srcdir"/thread_manager.c \
        -pthread \
        -ljson-c \
        -lsqlite3
}

package() {
    install -Dm755 thread_manager "$pkgdir"/usr/sbin/thread_manager
    install -Dm755 "$srcdir"/thread-manager.initd "$pkgdir"/etc/init.d/thread-manager
}
EOF

# Create integration script for the build system
cat > "${BUILD_DIR}/${THREAD_MANAGER_DIR}/integrate.sh" << 'EOF'
#!/bin/bash
set -e

# Add thread manager to the base system
echo "thread-manager" >> /etc/apk/world

# Enable the service
rc-update add thread-manager default

# Create configuration directory
mkdir -p /etc/thread-manager
EOF

chmod +x "${BUILD_DIR}/${THREAD_MANAGER_DIR}/scripts/build.sh"
chmod +x "${BUILD_DIR}/${THREAD_MANAGER_DIR}/scripts/thread-manager.initd"
chmod +x "${BUILD_DIR}/${THREAD_MANAGER_DIR}/integrate.sh"

echo "Thread manager integration files created successfully!"