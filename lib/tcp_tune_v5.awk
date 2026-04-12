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

function exp_curve(x, base, scale) {
    return scale * exp((x - 1) * log(base))
}

function log_curve(x, base, scale) {
    return scale * log(x * (base - 1) + 1) / log(base)
}

function sigmoid_curve(x, steepness, midpoint) {
    return 1 / (1 + exp(-steepness * (x - midpoint)))
}

function linear_curve(x, a, b) {
    return a * x + b
}

function tcp_cong_curve(x, mode, base) {
    if (mode == "slow_start") {
        return minv(base * (1 + 0.5 * x), base + 10 * x)
    }
    return base + 0.1 * x
}

function queue_theory_curve(x, factor, rho) {
    return factor / (1 - minv(rho, 0.95)) * x
}

function bdp(bw_bps, latency_ms, scale) {
    return ceilv(bw_bps * latency_ms * scale / 1000)
}

function mem_buffer_limit(value, mem_mb, ratio) {
    return minv(value, 1024 * mem_mb * 1024 * ratio)
}

function curve_output(x, lo, hi, y) {
    y = clampv(x, lo, hi)
    return y <= 0 ? lo : y
}

function piecewise_high_buffer(x) {
    if (x <= 0) {
        return 1
    }
    if (x <= 0.3) {
        return 1 + (x / 0.3) * 0.5
    }
    if (x <= 0.6) {
        return 1.5 + ((x - 0.3) / 0.3) * 1.0
    }
    if (x <= 1.0) {
        return 2.5 + ((x - 0.6) / 0.4) * 1.5
    }
    return 4
}

function set_low_profile(mem) {
    low_responsiveness = 2
    low_jitter_tolerance = 0.3
    low_burst_handling = 0.7
    low_memory_efficiency = 1
    low_buffer_aggression = 0.8
    low_queue_pref = 0.8
    low_conn_density = 1.2
    low_ws_base = 1.2
    low_ws_latency = 1.5
    low_ws_max = 4
    low_buf_steep = 4
    low_buf_mid = 0.3
    low_lat_sens = 2

    if (mem <= 256) {
        low_responsiveness = 2.5
        low_jitter_tolerance = 0.2
        low_burst_handling = 0.5
        low_memory_efficiency = 0.8
        low_buffer_aggression = 0.6
        low_queue_pref = 0.6
        low_conn_density = 1
        low_ws_base = 1
        low_ws_max = 3
    } else if (mem <= 512) {
        low_responsiveness = 2.2
        low_jitter_tolerance = 0.25
        low_burst_handling = 0.6
        low_memory_efficiency = 0.9
        low_buffer_aggression = 0.7
    } else if (mem > 1024) {
        low_responsiveness = 1.8
        low_jitter_tolerance = 0.4
        low_burst_handling = 0.9
        low_memory_efficiency = 1.2
        low_buffer_aggression = 1
        low_queue_pref = 1
        low_conn_density = 1.5
        low_ws_base = 1.4
        low_ws_max = 6
    }
}

function set_high_profile(mem) {
    high_throughput_priority = 2
    high_stability_factor = 1.5
    high_buffer_aggression = 2
    high_queue_depth = 2.5
    high_conn_scaling = 2
    high_memory_util = 1.5
    high_buffer_pooling = 1.5
    high_ws_base = 2
    high_ws_latency = 2
    high_ws_max = 8
    high_lat_tolerance = 1.5

    if (mem <= 512) {
        high_throughput_priority = 1.8
        high_stability_factor = 1.8
        high_buffer_aggression = 1.5
        high_queue_depth = 2
        high_conn_scaling = 1.5
        high_memory_util = 1.2
        high_buffer_pooling = 1.2
        high_ws_base = 1.5
        high_ws_max = 6
    } else if (mem <= 1024) {
        return
    } else if (mem <= 2048) {
        high_throughput_priority = 2.2
        high_buffer_aggression = 2.3
        high_queue_depth = 3
        high_conn_scaling = 2.5
        high_memory_util = 1.8
        high_buffer_pooling = 1.8
        high_ws_base = 2.5
        high_ws_max = 12
    } else {
        high_throughput_priority = 2.5
        high_buffer_aggression = 2.5
        high_queue_depth = 3.5
        high_conn_scaling = 3
        high_memory_util = 2
        high_buffer_pooling = 2
        high_ws_base = 3
        high_ws_max = 16
    }
}

function set_cfg(key, value) {
    cfg[key] = value
}

function build_common_low(tcp_rmem, tcp_wmem, buf_limit, somaxconn, backlog, syn_backlog, adv_scale) {
    set_cfg("net.core.default_qdisc", qdisc)
    set_cfg("net.core.netdev_max_backlog", backlog)
    set_cfg("net.core.rmem_max", buf_limit)
    set_cfg("net.core.wmem_max", buf_limit)
    set_cfg("net.core.rmem_default", 87380)
    set_cfg("net.core.wmem_default", 65536)
    set_cfg("net.core.somaxconn", somaxconn)
    set_cfg("net.core.optmem_max", floorv(minv(65536, low_I / 4)))
    set_cfg("net.ipv4.tcp_fastopen", 3)
    set_cfg("net.ipv4.tcp_timestamps", 1)
    set_cfg("net.ipv4.tcp_tw_reuse", 1)
    set_cfg("net.ipv4.tcp_fin_timeout", 10)
    set_cfg("net.ipv4.tcp_slow_start_after_idle", 0)
    set_cfg("net.ipv4.tcp_max_tw_buckets", 32768)
    set_cfg("net.ipv4.tcp_sack", 1)
    set_cfg("net.ipv4.tcp_fack", 0)
    set_cfg("net.ipv4.tcp_rmem", tcp_rmem)
    set_cfg("net.ipv4.tcp_wmem", tcp_wmem)
    set_cfg("net.ipv4.tcp_mtu_probing", 1)
    set_cfg("net.ipv4.tcp_congestion_control", cc_algo)
    set_cfg("net.ipv4.tcp_notsent_lowat", 4096)
    set_cfg("net.ipv4.tcp_window_scaling", 1)
    set_cfg("net.ipv4.tcp_adv_win_scale", clampv(maxv(2, ceilv(adv_scale)), 2, 8))
    set_cfg("net.ipv4.tcp_moderate_rcvbuf", 1)
    set_cfg("net.ipv4.tcp_no_metrics_save", 0)
    set_cfg("net.ipv4.tcp_max_syn_backlog", syn_backlog)
    set_cfg("net.ipv4.tcp_max_orphans", mem_mb <= 256 ? 16384 : 32768)
    set_cfg("net.ipv4.tcp_synack_retries", 2)
    set_cfg("net.ipv4.tcp_syn_retries", 3)
    set_cfg("net.ipv4.tcp_abort_on_overflow", 0)
    set_cfg("net.ipv4.tcp_syncookies", 1)
    set_cfg("net.ipv4.ip_local_port_range", "1024 65535")
    set_cfg("vm.min_free_kbytes", clampv(floorv(1024 * mem_mb * (mem_mb <= 256 ? 0.015 : (mem_mb <= 512 ? 0.02 : (mem_mb <= 1024 ? 0.025 : 0.03))) + floorv(0.5 * ceilv(low_T / 1024))), 32768, 1048576))
}

function build_common_high(tcp_rmem, tcp_wmem, buf_limit, somaxconn, backlog, syn_backlog, adv_scale) {
    set_cfg("net.core.default_qdisc", qdisc)
    set_cfg("net.core.netdev_max_backlog", backlog)
    set_cfg("net.core.rmem_max", buf_limit)
    set_cfg("net.core.wmem_max", buf_limit)
    set_cfg("net.core.rmem_default", 262144)
    set_cfg("net.core.wmem_default", 262144)
    set_cfg("net.core.somaxconn", somaxconn)
    set_cfg("net.core.optmem_max", floorv(minv(262144, high_j / 2)))
    set_cfg("net.ipv4.tcp_fastopen", 3)
    set_cfg("net.ipv4.tcp_timestamps", 1)
    set_cfg("net.ipv4.tcp_tw_reuse", 1)
    set_cfg("net.ipv4.tcp_fin_timeout", 10)
    set_cfg("net.ipv4.tcp_slow_start_after_idle", 0)
    set_cfg("net.ipv4.tcp_max_tw_buckets", 32768)
    set_cfg("net.ipv4.tcp_sack", 1)
    set_cfg("net.ipv4.tcp_fack", 1)
    set_cfg("net.ipv4.tcp_rmem", tcp_rmem)
    set_cfg("net.ipv4.tcp_wmem", tcp_wmem)
    set_cfg("net.ipv4.tcp_mtu_probing", 1)
    set_cfg("net.ipv4.tcp_congestion_control", cc_algo)
    set_cfg("net.ipv4.tcp_notsent_lowat", floorv(minv(high_j / 2, 524288)))
    set_cfg("net.ipv4.tcp_window_scaling", 1)
    set_cfg("net.ipv4.tcp_adv_win_scale", clampv(maxv(2, ceilv(adv_scale)), 2, 8))
    set_cfg("net.ipv4.tcp_moderate_rcvbuf", 1)
    set_cfg("net.ipv4.tcp_no_metrics_save", 1)
    set_cfg("net.ipv4.tcp_max_syn_backlog", syn_backlog)
    set_cfg("net.ipv4.tcp_max_orphans", mem_mb <= 256 ? 16384 : 32768)
    set_cfg("net.ipv4.tcp_synack_retries", 2)
    set_cfg("net.ipv4.tcp_syn_retries", 2)
    set_cfg("net.ipv4.tcp_abort_on_overflow", 0)
    set_cfg("net.ipv4.tcp_syncookies", 1)
    set_cfg("net.ipv4.ip_local_port_range", "1024 65535")
    set_cfg("vm.min_free_kbytes", clampv(floorv(1024 * mem_mb * (mem_mb <= 512 ? 0.02 : (mem_mb <= 1024 ? 0.025 : (mem_mb <= 2048 ? 0.03 : 0.035))) + floorv(0.6 * ceilv(high_bw_bps / 1024))), 65536, 1048576))
}

function calc_low(    ratio, ratio_scale, mem_ratio, hard_min, h_scale, v_scale, curve1, latency_factor, buffer_factor, queue_factor, adv_factor, tcp_rmax, tcp_wmax, queue_base, queue_mult, somaxconn, backlog, syn_backlog) {
    set_low_profile(mem_mb)

    low_F = clampv(1.5 * sqrt(client_bw_mbps / vps_bw_mbps), 1, 2)
    low_T = 1024 * minv(client_bw_mbps * low_F, vps_bw_mbps) * 1024 / 8

    ratio = client_bw_mbps / vps_bw_mbps
    ratio_scale = 1
    if (ratio > 1) {
        ratio_scale = maxv(0.3, 1 / sqrt(minv(ratio, 100)))
        if (latency_ms > 200) {
            ratio_scale = minv(1, 1.2 * ratio_scale)
        }
    }

    low_P = ceilv(low_T * latency_ms / 1000)
    low_I = maxv(low_P, 24576)
    mem_ratio = (mem_mb <= 256) ? 0.1 : 0.125
    hard_min = (mem_mb <= 256) ? 4194304 : 8388608
    low_U = maxv(mem_buffer_limit(ceilv(1.5 * ramp_rate * ratio_scale * low_P), mem_mb, mem_ratio), hard_min)

    curve1 = curve_output(sigmoid_curve(ramp_rate, low_buf_steep, low_buf_mid) * (low_responsiveness / 2), 0.3, 2)
    latency_factor = curve_output(exp_curve(latency_ms / 120, low_lat_sens, 1) * curve1 * low_responsiveness, 0.8, 5)
    buffer_factor = curve_output(latency_factor * tcp_cong_curve(curve1, "slow_start", 1) * low_memory_efficiency * low_buffer_aggression * low_burst_handling, 0.5, 3)
    # Keep queue growth slightly conservative on unmanaged VPS links to avoid
    # over-sizing backlog/syn queues from transient probe jitter.
    queue_factor = curve_output((log(queue_theory_curve(low_T / 65536 * low_conn_density, latency_ms / 1000 * 2, 0.8 * curve1) + 1) / log(1000)) * low_queue_pref * (1 + low_jitter_tolerance), 0.3, 2)
    adv_factor = curve_output(latency_factor / low_ws_latency * (maxv(0, ceilv(log(2 * bdp(low_T, latency_ms, 1) / 65535) / log(2))) * low_ws_base) * curve1, 1, low_ws_max)

    h_scale = (mem_mb <= 256) ? 2.5 : (mem_mb <= 512 ? 3 : 4)
    v_scale = (mem_mb <= 256) ? 1.2 : (mem_mb <= 512 ? 1.5 : 2)

    tcp_rmax = minv(floorv(low_I * h_scale * buffer_factor), low_U)
    tcp_wmax = minv(floorv(low_I * v_scale * buffer_factor), low_U)

    queue_base = ceilv(minv(2 * maxv(100, low_T / 65536), 10000) * queue_factor)
    queue_mult = (mem_mb <= 256) ? 0.6 : (mem_mb <= 512 ? 0.8 : (mem_mb <= 1024 ? 1 : 1.2))
    somaxconn = clampv(floorv(0.2 * queue_base * queue_mult), 256, 2048)
    backlog = clampv(floorv(0.4 * queue_base * queue_mult), 2000, 4000)
    syn_backlog = clampv(floorv(0.8 * queue_base * queue_mult), 2048, 16384)

    build_common_low("8192 87380 " tcp_rmax, "8192 65536 " tcp_wmax, low_U, somaxconn, backlog, syn_backlog, adv_factor)

    if (extreme_mode == 1) {
        low_ext_buf = floorv(maxv(minv(low_T * latency_ms / 1000 * minv(8, 4 + mem_mb / 2048), 1024 * mem_mb * 122.88), 2097152))
        low_ext_cap = minv(4 * mem_mb, 16384)
        low_ext_extra = minv(low_T / 1048576, 10000)
        low_ext_backlog = minv(low_ext_cap, 4000 + low_ext_extra)
        low_ext_syn = minv(low_ext_cap / 2, 2048 + low_ext_extra / 2)

        set_cfg("net.core.rmem_max", 2 * low_ext_buf)
        set_cfg("net.core.wmem_max", low_ext_buf)
        set_cfg("net.core.rmem_default", 262144)
        set_cfg("net.core.wmem_default", 262144)
        set_cfg("net.ipv4.tcp_rmem", "32768 262144 " (2 * low_ext_buf))
        set_cfg("net.ipv4.tcp_wmem", "32768 262144 " low_ext_buf)
        set_cfg("net.core.netdev_max_backlog", low_ext_backlog)
        set_cfg("net.core.somaxconn", 16384)
        set_cfg("net.ipv4.tcp_max_syn_backlog", low_ext_syn)
        set_cfg("net.ipv4.tcp_mtu_probing", 2)
        set_cfg("net.ipv4.tcp_timestamps", 0)
        set_cfg("net.ipv4.tcp_window_scaling", 1)
        set_cfg("net.ipv4.tcp_sack", 1)
        set_cfg("net.ipv4.tcp_fack", 1)
        set_cfg("net.ipv4.tcp_notsent_lowat", 16384)
        set_cfg("net.core.default_qdisc", "fq")
        set_cfg("vm.min_free_kbytes", maxv(131072, 32 * mem_mb))
        set_cfg("net.ipv4.tcp_mem", (384 * mem_mb) " " (512 * mem_mb) " " (768 * mem_mb))
        set_cfg("net.ipv4.tcp_keepalive_time", 600)
        set_cfg("net.ipv4.tcp_keepalive_intvl", 30)
        set_cfg("net.ipv4.tcp_keepalive_probes", 3)
        set_cfg("net.ipv4.tcp_fin_timeout", 15)
        set_cfg("net.ipv4.tcp_moderate_rcvbuf", 0)
        set_cfg("net.core.optmem_max", minv(81920, 80 * mem_mb))
    }
}

function calc_high(    ratio, p_ratio, curve1, latency_factor, buffer_factor, queue_factor, adv_factor, base_bdp, floor_bdp, w_limit, scale_k, scale_q, tcp_rmax, tcp_wmax, queue_base, queue_mult, somaxconn, backlog, syn_backlog) {
    set_high_profile(mem_mb)

    high_latency_scale = clampv(latency_ms / 40, 1, 5)
    high_ratio_factor = clampv(2 * sqrt(client_bw_mbps / vps_bw_mbps) * high_latency_scale, 1.5, 5)
    high_bw_bps = floorv(1024 * minv(client_bw_mbps * high_ratio_factor, 2 * vps_bw_mbps) * 1024 / 8)

    ratio = client_bw_mbps / vps_bw_mbps
    p_ratio = 1
    if (ratio > 100) {
        p_ratio = 0.06
    } else if (ratio > 50) {
        p_ratio = 0.12
    } else if (ratio > 20) {
        p_ratio = 0.2
    } else if (ratio > 10) {
        p_ratio = 0.3
    } else if (ratio > 5) {
        p_ratio = 0.5
    } else if (ratio > 2) {
        p_ratio = 0.7
    }

    curve1 = curve_output(log_curve(ramp_rate, exp(1), high_throughput_priority / 2) * high_stability_factor * (high_buffer_aggression / 2), 0.5, 3)
    latency_factor = curve_output(log_curve(minv(1, (latency_ms - 120) / 1880), high_lat_tolerance, 1) * high_ws_latency * curve1, 1, 8)
    buffer_factor = curve_output(latency_factor * tcp_cong_curve(curve1, "congestion_avoidance", 10) * high_throughput_priority * high_buffer_aggression * high_memory_util * piecewise_high_buffer(curve1), 1, 8)
    queue_factor = curve_output((latency_factor / 3) * (log(queue_theory_curve(high_bw_bps / 131072 * high_conn_scaling, latency_ms / 1000 * 3, minv(0.9, 0.85 * curve1)) + 1) / log(10000) * high_queue_depth), 0.8, 4)
    adv_factor = curve_output(latency_factor / high_ws_latency * (maxv(0, ceilv(log(4 * bdp(high_bw_bps, latency_ms, 1) / 65535) / log(2))) * high_ws_base) * linear_curve(curve1, 2, 1), 2, high_ws_max)

    base_bdp = ceilv(high_bw_bps * latency_ms / 1000)
    floor_bdp = maxv(base_bdp, 262144)
    high_j = maxv(floor_bdp, high_bw_bps * latency_ms / 800)
    if (mem_mb <= 512) {
        floor_bdp = maxv(base_bdp, 131072)
        high_j = maxv(floor_bdp, high_bw_bps * latency_ms / 1200)
    } else if (mem_mb <= 1024) {
        floor_bdp = maxv(base_bdp, 262144)
        high_j = maxv(floor_bdp, high_bw_bps * latency_ms / 1000)
    } else {
        floor_bdp = maxv(base_bdp, 524288)
        high_j = maxv(floor_bdp, high_bw_bps * latency_ms / 800)
    }

    high_H = ceilv(high_bw_bps * latency_ms / 1000)
    high_V = mem_buffer_limit(ceilv(2 * ramp_rate * p_ratio * high_H), mem_mb, 0.125)
    w_limit = high_V
    if (latency_ms > 500) {
        w_limit = maxv(high_V, ceilv(0.5 * high_H))
    }

    scale_k = minv(8, maxv(4, 1.8 * high_latency_scale)) * buffer_factor
    scale_q = minv(10, maxv(5, 2 * high_latency_scale))
    if (mem_mb <= 512) {
        scale_k = minv(6, maxv(3, 1.5 * high_latency_scale)) * buffer_factor
        scale_q = minv(6, maxv(3, 1.5 * high_latency_scale))
    } else if (mem_mb <= 1024) {
        scale_k = minv(8, maxv(4, 1.8 * high_latency_scale)) * buffer_factor
        scale_q = minv(8, maxv(4, 1.8 * high_latency_scale))
    } else {
        scale_k = minv(10, maxv(5, 2 * high_latency_scale)) * buffer_factor
        scale_q = minv(10, maxv(5, 2 * high_latency_scale))
    }

    tcp_rmax = minv(floorv(high_j * scale_q), w_limit)
    tcp_wmax = minv(floorv(high_j * scale_k), w_limit)

    queue_base = ceilv(minv(3 * maxv(50, high_bw_bps / 131072), 20000) * queue_factor)
    queue_mult = (mem_mb <= 512) ? 0.8 : (mem_mb <= 1024 ? 1 : (mem_mb <= 2048 ? 1.3 : 1.5))
    somaxconn = clampv(floorv(0.15 * queue_base * queue_mult), 2560, mem_mb <= 512 ? 8192 : 16384)
    backlog = clampv(floorv(0.3 * queue_base * queue_mult), 8192, mem_mb <= 512 ? 16384 : 32768)
    syn_backlog = clampv(floorv(0.6 * queue_base * queue_mult), 8192, mem_mb <= 512 ? 32768 : 65536)

    build_common_high("32768 262144 " tcp_rmax, "32768 262144 " tcp_wmax, w_limit, somaxconn, backlog, syn_backlog, high_latency_scale * adv_factor)

    if (extreme_mode == 1) {
        high_ext_buf = floorv(maxv(minv(high_bw_bps * latency_ms / 1000 * minv(12, 6 + mem_mb / 1024), 1024 * mem_mb * 153.6), 4194304))
        high_ext_k = minv(latency_ms / 100, 5)
        high_ext_q = minv(high_bw_bps / 1048576, 15000)
        high_ext_backlog = minv(minv(6 * mem_mb, 24576), 6000 + high_ext_q * high_ext_k)
        high_ext_syn = minv(high_ext_backlog / 2, 3000 + high_ext_q * high_ext_k / 2)

        set_cfg("net.core.rmem_max", 2 * high_ext_buf)
        set_cfg("net.core.wmem_max", high_ext_buf)
        set_cfg("net.core.rmem_default", 524288)
        set_cfg("net.core.wmem_default", 524288)
        set_cfg("net.ipv4.tcp_rmem", "65536 524288 " (2 * high_ext_buf))
        set_cfg("net.ipv4.tcp_wmem", "65536 524288 " high_ext_buf)
        set_cfg("net.core.netdev_max_backlog", high_ext_backlog)
        set_cfg("net.core.somaxconn", 32768)
        set_cfg("net.ipv4.tcp_max_syn_backlog", high_ext_syn)
        set_cfg("net.ipv4.tcp_mtu_probing", 2)
        set_cfg("net.ipv4.tcp_window_scaling", 1)
        set_cfg("net.ipv4.tcp_sack", 1)
        set_cfg("net.ipv4.tcp_fack", 1)
        set_cfg("net.ipv4.tcp_notsent_lowat", 32768)
        set_cfg("net.core.default_qdisc", "fq")
        set_cfg("net.ipv4.tcp_timestamps", 1)
        set_cfg("vm.min_free_kbytes", maxv(262144, 64 * mem_mb))
        set_cfg("net.ipv4.tcp_mem", (512 * mem_mb) " " (768 * mem_mb) " " (1024 * mem_mb))
        set_cfg("net.ipv4.tcp_keepalive_time", 1200)
        set_cfg("net.ipv4.tcp_keepalive_intvl", 60)
        set_cfg("net.ipv4.tcp_keepalive_probes", 3)
        set_cfg("net.ipv4.tcp_fin_timeout", 30)
        set_cfg("net.ipv4.tcp_moderate_rcvbuf", 0)
        set_cfg("net.core.optmem_max", minv(163840, 160 * mem_mb))
    }
}

function emit_cfg(    order, i, n, key) {
    n = split("net.core.default_qdisc net.core.netdev_max_backlog net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default net.core.somaxconn net.core.optmem_max net.ipv4.tcp_fastopen net.ipv4.tcp_timestamps net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_sack net.ipv4.tcp_fack net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mtu_probing net.ipv4.tcp_congestion_control net.ipv4.tcp_notsent_lowat net.ipv4.tcp_window_scaling net.ipv4.tcp_adv_win_scale net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_no_metrics_save net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_orphans net.ipv4.tcp_synack_retries net.ipv4.tcp_syn_retries net.ipv4.tcp_abort_on_overflow net.ipv4.tcp_syncookies net.ipv4.ip_local_port_range net.ipv4.tcp_mem net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes vm.min_free_kbytes", order, " ")
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
        ramp_rate = 0.58
    }
    if (cc_algo == "" || cc_algo == "auto") {
        cc_algo = "bbr"
    }
    if (qdisc == "" || qdisc == "auto") {
        qdisc = "fq"
    }

    client_bw_mbps += 0
    vps_bw_mbps += 0
    latency_ms += 0
    mem_mb += 0
    ramp_rate += 0
    extreme_mode += 0

    if (path_mode == "low") {
        calc_low()
    } else if (path_mode == "high") {
        calc_high()
    } else if (latency_ms > 120) {
        calc_high()
    } else {
        calc_low()
    }

    emit_cfg()
}
