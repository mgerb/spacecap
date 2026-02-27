pub const PipewireTimestampSource = enum {
    meta_pts,
    pwb_time,
    stream_nsec,
    stream_time_now,
    host,
};
