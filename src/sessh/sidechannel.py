from __future__ import annotations

from dataclasses import dataclass


OSC = b"\x1b]"
BEL = b"\x07"


@dataclass(frozen=True)
class SideChannelEvent:
    name: str
    fields: tuple[str, ...]


class SideChannelParser:
    def __init__(self, nonce: str):
        self._prefix = OSC + b"sessh;" + nonce.encode("ascii") + b"\t"
        self._buffer = b""

    def feed(self, data: bytes) -> tuple[bytes, list[SideChannelEvent]]:
        self._buffer += data
        visible: list[bytes] = []
        events: list[SideChannelEvent] = []

        while self._buffer:
            frame_start = self._buffer.find(self._prefix)
            if frame_start < 0:
                keep = self._partial_prefix_length(self._buffer)
                if keep == 0:
                    visible.append(self._buffer)
                    self._buffer = b""
                    break
                if len(self._buffer) <= keep:
                    break
                visible.append(self._buffer[:-keep])
                self._buffer = self._buffer[-keep:]
                break

            if frame_start:
                visible.append(self._buffer[:frame_start])
                self._buffer = self._buffer[frame_start:]

            frame_end = self._buffer.find(BEL, len(self._prefix))
            if frame_end < 0:
                break

            payload = self._buffer[len(self._prefix) : frame_end]
            event = self._parse_payload(payload)
            if event is not None:
                events.append(event)
            self._buffer = self._buffer[frame_end + 1 :]

        return b"".join(visible), events

    def flush(self) -> bytes:
        remaining = self._buffer
        self._buffer = b""
        return remaining

    def _parse_payload(self, payload: bytes) -> SideChannelEvent | None:
        fields = payload.split(b"\t")
        if not fields or not fields[0]:
            return None
        try:
            decoded = tuple(field.decode("utf-8", "strict") for field in fields)
        except UnicodeDecodeError:
            return None
        return SideChannelEvent(decoded[0], decoded[1:])

    def _partial_prefix_length(self, data: bytes) -> int:
        max_length = min(len(data), len(self._prefix) - 1)
        for length in range(max_length, 0, -1):
            if data[-length:] == self._prefix[:length]:
                return length
        return 0


def format_sidechannel_frame(nonce: str, event: str, *fields: str) -> bytes:
    payload = "\t".join((event, *fields)).encode("utf-8")
    return OSC + b"sessh;" + nonce.encode("ascii") + b"\t" + payload + BEL
