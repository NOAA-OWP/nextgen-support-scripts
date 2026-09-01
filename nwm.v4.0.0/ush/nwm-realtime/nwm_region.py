from abc import ABC


class NWMRegion(ABC):
    """Abstract base class representing an NWM forecast region."""

    def __init__(self, id: str, case_type: str, hydrofabric: str):
        self._id: str = id
        self._jobstatus: str | None = None  # "succeed", "failed", or None
        self._case_type: str = case_type
        self._hydrofabric: str = hydrofabric

    @property
    def id(self) -> str:
        return self._id

    @id.setter
    def id(self, value: str) -> None:
        self._id = value

    @property
    def jobstatus(self) -> str | None:
        return self._jobstatus

    @jobstatus.setter
    def jobstatus(self, value: str | None) -> None:
        self._jobstatus = value

    @property
    def case_type(self) -> str:
        return self._case_type

    @case_type.setter
    def case_type(self, value: str) -> None:
        self._case_type = value

    @property
    def hydrofabric(self) -> str:
        return self._hydrofabric

    @hydrofabric.setter
    def hydrofabric(self, value: str) -> None:
        self._hydrofabric = value

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, NWMRegion):
            return NotImplemented
        return self._id == other._id

    def __hash__(self) -> int:
        return hash(self._id)


class VPU(NWMRegion):
    """NWM region defined by a Vector Processing Unit (VPU)."""

    def __init__(self, id: str, case_type: str, hydrofabric: str,
                 formulation_assignment: str, catchment_group: str):
        super().__init__(id, case_type, hydrofabric)
        self._formulation_assignment: str = formulation_assignment
        self._catchment_group: str = catchment_group

    @property
    def formulation_assignment(self) -> str:
        return self._formulation_assignment

    @formulation_assignment.setter
    def formulation_assignment(self, value: str) -> None:
        self._formulation_assignment = value

    @property
    def catchment_group(self) -> str:
        return self._catchment_group

    @catchment_group.setter
    def catchment_group(self, value: str) -> None:
        self._catchment_group = value


class Basin(NWMRegion):
    """NWM region defined by a hydrologic basin (gage ID)."""

    def __init__(self, id: str, case_type: str, hydrofabric: str):
        super().__init__(id, case_type, hydrofabric)
