function minv(a, b) {
    return a < b ? a : b
}

function maxv(a, b) {
    return a > b ? a : b
}

function clampv(x, lo, hi) {
    if (x < lo) {
        return lo
    }
    if (x > hi) {
        return hi
    }
    return x
}

function floorv(x) {
    return int(x + 0.0000001)
}

function ceilv(x, n) {
    n = int(x)
    return (x > n) ? (n + 1) : n
}

function set_cfg(key, value) {
    cfg[key] = value
}

function scale_factor(x, base_scale, lo, hi, mult) {
    return base_scale * clampv(x * mult, lo, hi)
}

function min_free_low(p_bw, mem_mb) {
    if (mem_mb <= 256) {
        return minv(maxv(32768, floorv(p_bw / 1024 * 0.8)), 262144)
    }
    if (mem_mb <= 512) {
        return minv(maxv(65536, floorv(p_bw / 1024)), 524288)
    }
    return minv(maxv(131072, floorv(p_bw / 1024 * 1.2)), 1048576)
}

function min_free_high(p_bw, mem_mb) {
    if (mem_mb <= 256) {
        return minv(maxv(32768, floorv(p_bw / 1024 * 0.5)), 262144)
    }
    if (mem_mb <= 512) {
        return minv(maxv(65536, floorv(p_bw / 1024 * 0.8)), 524288)
    }
    return minv(maxv(131072, floorv(p_bw / 1024)), 1048576)
}

function buffer_cap_low(mem_mb) {
    if (mem_mb <= 256) {
        return floorv(1024 * mem_mb * 1024 * 0.08)
    }
    if (mem_mb <= 512) {
        return floorv(1024 * mem_mb * 1024 * 0.10)
    }
    if (mem_mb <= 1024) {
        return floorv(1024 * mem_mb * 1024 * 0.125)
    }
    return floorv(1024 * mem_mb * 1024 * 0.18)
}

function buffer_cap_high(mem_mb) {
    if (mem_mb <= 512) {
        return floorv(1024 * mem_mb * 1024 * 0.10)
    }
    if (mem_mb <= 1024) {
        return floorv(1024 * mem_mb * 1024 * 0.125)
    }
    if (mem_mb <= 2048) {
        return floorv(1024 * mem_mb * 1024 * 0.18)
    }
    return floorv(1024 * mem_mb * 1024 * 0.25)
}

function build_low(    bw_scale, base_bw_bps, base_bdp, ramp_scale, lat_term, buf_factor, queue_factor, adv_factor, rscale, wscale, tcp_rmax, tcp_wmax, buf_cap, somaxconn, backlog, syn_backlog) {
    bw_scale = minv(2, maxv(1, 1.5 * sqrt(client_bw_mbps / vps_bw_mbps)))
    base_bw_bps = 1024 * minv(client_bw_mbps * bw_scale, vps_bw_mbps) * 1024 / 8
    base_bdp = maxv(ceilv(base_bw_bps * latency_ms / 1000), 24576)

    ramp_scale = ramp_rate
    lat_term = scale_factor(latency_ms / 40, ramp_scale, 1, 5, 1)
    buf_factor = scale_factor(lat_term, ramp_scale, 3, 4, 1.5)
    queue_factor = scale_factor(lat_term, ramp_scale, 2, 3, 1)
    adv_factor = scale_factor(lat_term, ramp_scale, 1.5, 4, 1)

    rscale = (mem_mb <= 256) ? 2.5 : (mem_mb <= 512 ? 3 : 4)
    wscale = (mem_mb <= 256) ? 1.2 : (mem_mb <= 512 ? 1.5 : 2)

    # Conservative subset: cap V4 buffers by memory tier so auto mode does not
    # emit website-sized buffers that exceed practical VPS limits.
    buf_cap = buffer_cap_low(mem_mb)
    tcp_rmax = minv(floorv(base_bdp * rscale * buf_factor), buf_cap)
    tcp_wmax = minv(floorv(base_bdp * wscale * buf_factor), buf_cap)
    somaxconn = floorv(clampv(ceilv(base_bw_bps / 262144), 256, 2048) * queue_factor)
    backlog = floorv(clampv(ceilv(base_bw_bps / 131072), 2000, 4000) * queue_factor)
    syn_backlog = floorv(clampv(ceilv(base_bw_bps / 65536), 2048, 16384) * queue_factor)

    set_cfg("net.core.default_qdisc", qdisc)
    set_cfg("net.core.netdev_max_backlog", backlog)
    set_cfg("net.core.rmem_max", tcp_rmax)
    set_cfg("net.core.wmem_max", tcp_wmax)
    set_cfg("net.core.rmem_default", 87380)
    set_cfg("net.core.wmem_default", 65536)
    set_cfg("net.core.somaxconn", somaxconn)
    set_cfg("net.core.optmem_max", floorv(minv(65536, base_bdp / 4)))
    set_cfg("net.ipv4.tcp_fastopen", 3)
    set_cfg("net.ipv4.tcp_timestamps", 1)
    set_cfg("net.ipv4.tcp_tw_reuse", 1)
    set_cfg("net.ipv4.tcp_fin_timeout", 10)
    set_cfg("net.ipv4.tcp_slow_start_after_idle", 0)
    set_cfg("net.ipv4.tcp_max_tw_buckets", 32768)
    set_cfg("net.ipv4.tcp_sack", 1)
    set_cfg("net.ipv4.tcp_fack", 0)
    set_cfg("net.ipv4.tcp_rmem", "8192 87380 " tcp_rmax)
    set_cfg("net.ipv4.tcp_wmem", "8192 65536 " tcp_wmax)
    set_cfg("net.ipv4.tcp_mtu_probing", 1)
    set_cfg("net.ipv4.tcp_congestion_control", cc_algo)
    set_cfg("net.ipv4.tcp_notsent_lowat", 4096)
    set_cfg("net.ipv4.tcp_window_scaling", 1)
    set_cfg("net.ipv4.tcp_adv_win_scale", maxv(2, ceilv(adv_factor)))
    set_cfg("net.ipv4.tcp_moderate_rcvbuf", 1)
    set_cfg("net.ipv4.tcp_no_metrics_save", 0)
    set_cfg("net.ipv4.tcp_max_syn_backlog", syn_backlog)
    set_cfg("net.ipv4.tcp_max_orphans", mem_mb <= 256 ? 16384 : 32768)
    set_cfg("net.ipv4.tcp_synack_retries", 2)
    set_cfg("net.ipv4.tcp_syn_retries", 3)
    set_cfg("net.ipv4.tcp_abort_on_overflow", 0)
    set_cfg("net.ipv4.tcp_syncookies", 1)
    set_cfg("net.ipv4.ip_local_port_range", "1024 65535")
    set_cfg("vm.min_free_kbytes", min_free_low(base_bw_bps, mem_mb))
}

function build_high(    lat_scale, bw_scale, base_bw_bps, ramp_scale, lat_term, throughput_factor, queue_shape, adv_shape, base_bdp, high_cap, rscale, wscale, buf_cap, tcp_rmax, tcp_wmax, queue_factor, somaxconn, backlog, syn_backlog) {
    lat_scale = clampv(latency_ms / 40, 1, 5)
    bw_scale = minv(5, maxv(1.5, 2 * sqrt(client_bw_mbps / vps_bw_mbps) * lat_scale))
    base_bw_bps = floorv(1024 * minv(client_bw_mbps * bw_scale, 2 * vps_bw_mbps) * 1024 / 8)

    ramp_scale = ramp_rate * 1.2
    lat_term = scale_factor(latency_ms / 40, ramp_scale, 1, 5, 1)
    throughput_factor = scale_factor(lat_term, ramp_scale, 8, 15, 2.5)
    queue_shape = scale_factor(lat_term, ramp_scale, 4, 8, 2)
    adv_shape = scale_factor(lat_term, ramp_scale, 2, 10, 1.6)

    base_bdp = ceilv(base_bw_bps * latency_ms / 1000)
    high_cap = maxv(base_bdp, 262144)
    high_cap = maxv(high_cap, base_bw_bps * latency_ms / 800)
    if (mem_mb <= 512) {
        high_cap = maxv(base_bdp > 131072 ? base_bdp : 131072, base_bw_bps * latency_ms / 1200)
    } else if (mem_mb <= 1024) {
        high_cap = maxv(base_bdp > 262144 ? base_bdp : 262144, base_bw_bps * latency_ms / 1000)
    } else {
        high_cap = maxv(base_bdp > 524288 ? base_bdp : 524288, base_bw_bps * latency_ms / 800)
    }

    if (mem_mb <= 512) {
        rscale = minv(12, maxv(6, 2.2 * lat_scale))
        wscale = minv(12, maxv(6, 2.2 * lat_scale)) * throughput_factor
    } else if (mem_mb <= 1024) {
        rscale = minv(18, maxv(9, 2.8 * lat_scale))
        wscale = minv(18, maxv(9, 2.8 * lat_scale)) * throughput_factor
    } else {
        rscale = minv(22, maxv(11, 3.2 * lat_scale))
        wscale = minv(22, maxv(11, 3.2 * lat_scale)) * throughput_factor
    }

    # Conservative subset: cap V4 buffers by memory tier for safer defaults.
    buf_cap = buffer_cap_high(mem_mb)
    tcp_rmax = minv(floorv(high_cap * rscale), buf_cap)
    tcp_wmax = minv(floorv(high_cap * wscale), buf_cap)
    queue_factor = minv(9, maxv(4.5, 2.2 * lat_scale)) * queue_shape
    if (mem_mb <= 512) {
        somaxconn = floorv(minv(maxv(2560, ceilv(base_bw_bps / 32768 * minv(4.5, maxv(2.3, 1.2 * lat_scale)) * queue_shape)), 20480))
        backlog = floorv(minv(maxv(40000, ceilv(base_bw_bps / 8192 * queue_factor)), 80000))
        syn_backlog = floorv(minv(maxv(20480, ceilv(base_bw_bps / 4096 * queue_factor)), 163840))
    } else if (mem_mb <= 1024) {
        somaxconn = floorv(minv(maxv(2560, ceilv(base_bw_bps / 32768 * minv(7, maxv(3.5, 1.8 * lat_scale)) * queue_shape)), 40960))
        backlog = floorv(minv(maxv(40000, ceilv(base_bw_bps / 8192 * queue_factor)), 80000))
        syn_backlog = floorv(minv(maxv(20480, ceilv(base_bw_bps / 4096 * queue_factor)), 327680))
    } else {
        somaxconn = floorv(minv(maxv(2560, ceilv(base_bw_bps / 32768 * minv(9, maxv(4.5, 2.2 * lat_scale)) * queue_shape)), 40960))
        backlog = floorv(minv(maxv(40000, ceilv(base_bw_bps / 8192 * queue_factor)), 80000))
        syn_backlog = floorv(minv(maxv(20480, ceilv(base_bw_bps / 4096 * queue_factor)), 327680))
    }

    set_cfg("net.core.default_qdisc", qdisc)
    set_cfg("net.core.netdev_max_backlog", backlog)
    set_cfg("net.core.rmem_max", tcp_rmax)
    set_cfg("net.core.wmem_max", tcp_wmax)
    set_cfg("net.core.rmem_default", 262144)
    set_cfg("net.core.wmem_default", 262144)
    set_cfg("net.core.somaxconn", somaxconn)
    set_cfg("net.core.optmem_max", floorv(minv(262144, high_cap / 2)))
    set_cfg("net.ipv4.tcp_fastopen", 3)
    set_cfg("net.ipv4.tcp_timestamps", 1)
    set_cfg("net.ipv4.tcp_tw_reuse", 1)
    set_cfg("net.ipv4.tcp_fin_timeout", 10)
    set_cfg("net.ipv4.tcp_slow_start_after_idle", 0)
    set_cfg("net.ipv4.tcp_max_tw_buckets", 32768)
    set_cfg("net.ipv4.tcp_sack", 1)
    set_cfg("net.ipv4.tcp_fack", 1)
    set_cfg("net.ipv4.tcp_rmem", "32768 262144 " tcp_rmax)
    set_cfg("net.ipv4.tcp_wmem", "32768 262144 " tcp_wmax)
    set_cfg("net.ipv4.tcp_mtu_probing", 1)
    set_cfg("net.ipv4.tcp_congestion_control", cc_algo)
    set_cfg("net.ipv4.tcp_notsent_lowat", floorv(minv(high_cap / 2, 524288)))
    set_cfg("net.ipv4.tcp_window_scaling", 1)
    set_cfg("net.ipv4.tcp_adv_win_scale", clampv(maxv(2, ceilv(lat_scale * adv_shape)), 2, 8))
    set_cfg("net.ipv4.tcp_moderate_rcvbuf", 1)
    set_cfg("net.ipv4.tcp_no_metrics_save", 1)
    set_cfg("net.ipv4.tcp_max_syn_backlog", syn_backlog)
    set_cfg("net.ipv4.tcp_max_orphans", mem_mb <= 256 ? 16384 : 32768)
    set_cfg("net.ipv4.tcp_synack_retries", 2)
    set_cfg("net.ipv4.tcp_syn_retries", 2)
    set_cfg("net.ipv4.tcp_abort_on_overflow", 0)
    set_cfg("net.ipv4.tcp_syncookies", 1)
    set_cfg("net.ipv4.ip_local_port_range", "1024 65535")
    set_cfg("vm.min_free_kbytes", min_free_high(base_bw_bps, mem_mb))
}

function emit_cfg(    order, i, n, key) {
    n = split("net.core.default_qdisc net.core.netdev_max_backlog net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default net.core.somaxconn net.core.optmem_max net.ipv4.tcp_fastopen net.ipv4.tcp_timestamps net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_sack net.ipv4.tcp_fack net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mtu_probing net.ipv4.tcp_congestion_control net.ipv4.tcp_notsent_lowat net.ipv4.tcp_window_scaling net.ipv4.tcp_adv_win_scale net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_no_metrics_save net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_orphans net.ipv4.tcp_synack_retries net.ipv4.tcp_syn_retries net.ipv4.tcp_abort_on_overflow net.ipv4.tcp_syncookies net.ipv4.ip_local_port_range vm.min_free_kbytes", order, " ")
    for (i = 1; i <= n; i++) {
        key = order[i]
        if (key in cfg && cfg[key] != "") {
            printf "%s = %s\n", key, cfg[key]
        }
    }
}

BEGIN {
    if (client_bw_mbps == "") {
        client_bw_mbps = 1000
    }
    if (vps_bw_mbps == "") {
        vps_bw_mbps = client_bw_mbps
    }
    if (latency_ms == "") {
        latency_ms = 80
    }
    if (mem_mb == "") {
        mem_mb = 1024
    }
    if (ramp_rate == "") {
        ramp_rate = 0.56
    }
    if (cc_algo == "" || cc_algo == "auto") {
        cc_algo = "bbr"
    }
    if (qdisc == "" || qdisc == "auto") {
        qdisc = (latency_ms > 120 ? "fq" : "cake")
    }

    client_bw_mbps += 0
    vps_bw_mbps += 0
    latency_ms += 0
    mem_mb += 0
    ramp_rate += 0

    if (path_mode == "high") {
        build_high()
    } else if (path_mode == "low") {
        build_low()
    } else if (latency_ms > 120) {
        build_high()
    } else {
        build_low()
    }
    emit_cfg()
}
