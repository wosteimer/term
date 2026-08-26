const std = @import("std");

const Self = @This();
pub const DateTime = @This();

timestamp: u64,
year: u16,
month: u8,
day: u8,
hours: u8,
minutes: u8,
seconds: u8,

pub fn init(timestamp: u64) Self {
    const epoch = (std.time.epoch.EpochSeconds{ .secs = timestamp });
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seg = epoch.getDaySeconds();
    return .{
        .timestamp = timestamp,
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hours = day_seg.getHoursIntoDay(),
        .minutes = day_seg.getMinutesIntoHour(),
        .seconds = day_seg.getSecondsIntoMinute(),
    };
}

pub fn eql(self: *const Self, other: *const Self) bool {
    return self.timestamp == other.timestamp;
}

pub fn format(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print(
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ self.year, self.month, self.day, self.hours, self.minutes, self.seconds },
    );
}
