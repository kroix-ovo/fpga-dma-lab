"""DMA learning framework. DMA read/write permissions are device-relative."""

from .client import DmaClient, Region, Completion, DmaError, QueueFull

__all__ = ["DmaClient", "Region", "Completion", "DmaError", "QueueFull", "Status"]

from .registers import Status
