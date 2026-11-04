const wasi = {};
const wasiNoop = () => 0;
for (const name of [
    "args_get", "args_sizes_get", "environ_get", "environ_sizes_get",
    "clock_res_get", "clock_time_get", "fd_advise", "fd_allocate", "fd_close",
    "fd_datasync", "fd_fdstat_get", "fd_fdstat_set_flags", "fd_fdstat_set_rights",
    "fd_filestat_get", "fd_filestat_set_size", "fd_filestat_set_times", "fd_pread",
    "fd_prestat_get", "fd_prestat_dir_name", "fd_pwrite", "fd_read", "fd_readdir",
    "fd_renumber", "fd_seek", "fd_sync", "fd_tell", "fd_write",
    "path_create_directory", "path_filestat_get", "path_filestat_set_times",
    "path_link", "path_open", "path_readlink", "path_remove_directory", "path_rename",
    "path_symlink", "path_unlink_file", "poll_oneoff", "proc_exit", "proc_raise",
    "sched_yield", "random_get", "sock_accept", "sock_recv", "sock_send", "sock_shutdown"
]) wasi[name] = wasiNoop;
let wasiMemory = null;
wasi.fd_write = (fd, iovs, iovsLen, nwritten) => {
    if (!wasiMemory) return 0;
    const view = new DataView(wasiMemory.buffer);
    const decoder = new TextDecoder();
    let written = 0;
    let text = "";
    for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovs + i * 8, true);
        const len = view.getUint32(iovs + i * 8 + 4, true);
        text += decoder.decode(new Uint8Array(wasiMemory.buffer, ptr, len));
        written += len;
    }
    if (fd === 1 || fd === 2) {
        if (output) output.textContent += text;
        console.log(text);
    }
    view.setUint32(nwritten, written, true);
    return 0;
};
wasi.fd_prestat_get = () => 8;
wasi.clock_res_get = (id, ptr) => {
    if (wasiMemory) new DataView(wasiMemory.buffer).setBigUint64(ptr, 1n, true);
    return 0;
};
wasi.fd_fdstat_get = (fd, ptr) => {
    if (wasiMemory) {
        const view = new DataView(wasiMemory.buffer);
        view.setUint8(ptr, 2);
        view.setBigUint64(ptr + 8, 0xffffffffffffffffn, true);
        view.setBigUint64(ptr + 16, 0xffffffffffffffffn, true);
    }
    return 0;
};
wasi.args_sizes_get = (argc, argv) => {
    if (wasiMemory) {
        const view = new DataView(wasiMemory.buffer);
        view.setUint32(argc, 0, true);
        view.setUint32(argv, 0, true);
    }
    return 0;
};
wasi.environ_sizes_get = (count, size) => {
    if (wasiMemory) {
        const view = new DataView(wasiMemory.buffer);
        view.setUint32(count, 0, true);
        view.setUint32(size, 0, true);
    }
    return 0;
};
wasi.clock_time_get = (id, precision, ptr) => {
    if (wasiMemory) new DataView(wasiMemory.buffer).setBigUint64(ptr, 0n, true);
    return 0;
};
wasi.random_get = (ptr, len) => {
    if (wasiMemory) new Uint8Array(wasiMemory.buffer, ptr, len).fill(0);
    return 0;
};
wasi.proc_exit = (code) => { throw { wasiExit: code }; };
