from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def completed_day_interval(
    start_time: str, end_time: str, calendar_day: str, zone_identifier: str
) -> tuple[datetime, datetime] | None:
    """Validate exact calendar coverage independently of projection confidence."""
    try:
        day = date.fromisoformat(calendar_day)
        if day.isoformat() != calendar_day:
            return None
        zone = ZoneInfo(zone_identifier)
        start = datetime.combine(day, time.min, tzinfo=zone).astimezone(UTC)
        end = datetime.combine(
            day + timedelta(days=1), time.min, tzinfo=zone
        ).astimezone(UTC)
        # Round trips reject skipped days and boundaries that are not the first
        # instant of the local day, including unusual midnight transitions.
        if (
            start >= end
            or start.astimezone(zone).date() != day
            or (start - timedelta(microseconds=1)).astimezone(zone).date() >= day
            or (end - timedelta(microseconds=1)).astimezone(zone).date() != day
            or end.astimezone(zone).date() <= day
        ):
            return None
    except (ValueError, OverflowError, ZoneInfoNotFoundError):
        return None
    if (start_time, end_time) != (
        start.isoformat(timespec="seconds").replace("+00:00", "Z"),
        end.isoformat(timespec="seconds").replace("+00:00", "Z"),
    ):
        return None
    return start, end
