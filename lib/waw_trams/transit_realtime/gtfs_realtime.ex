defmodule TransitRealtime do
  @moduledoc """
  GTFS-Realtime Protocol Buffer definitions.

  Based on https://gtfs.org/realtime/proto/
  Only includes messages needed for vehicle positions.
  """

  # Feed Message - root container
  defmodule FeedMessage do
    @moduledoc "Root message for GTFS-Realtime feed"
    use Protobuf, syntax: :proto2

    field :header, 1, required: true, type: TransitRealtime.FeedHeader
    field :entity, 2, repeated: true, type: TransitRealtime.FeedEntity
  end

  defmodule FeedHeader do
    @moduledoc "Metadata about the feed"
    use Protobuf, syntax: :proto2

    field :gtfs_realtime_version, 1, required: true, type: :string

    field :incrementality, 2,
      optional: true,
      type: TransitRealtime.FeedHeader.Incrementality,
      enum: true,
      default: :FULL_DATASET

    field :timestamp, 3, optional: true, type: :uint64
  end

  defmodule FeedHeader.Incrementality do
    @moduledoc false
    use Protobuf, enum: true, syntax: :proto2

    field :FULL_DATASET, 0
    field :DIFFERENTIAL, 1
  end

  defmodule FeedEntity do
    @moduledoc "A single entity in the feed (vehicle, trip update, or alert)"
    use Protobuf, syntax: :proto2

    field :id, 1, required: true, type: :string
    field :is_deleted, 2, optional: true, type: :bool, default: false
    field :trip_update, 3, optional: true, type: TransitRealtime.TripUpdate
    field :vehicle, 4, optional: true, type: TransitRealtime.VehiclePosition
    field :alert, 5, optional: true, type: TransitRealtime.Alert
  end

  # Vehicle Position
  defmodule VehiclePosition do
    @moduledoc "Real-time position of a vehicle"
    use Protobuf, syntax: :proto2

    field :trip, 1, optional: true, type: TransitRealtime.TripDescriptor
    field :vehicle, 8, optional: true, type: TransitRealtime.VehicleDescriptor
    field :position, 2, optional: true, type: TransitRealtime.Position
    field :current_stop_sequence, 3, optional: true, type: :uint32
    field :stop_id, 7, optional: true, type: :string

    field :current_status, 4,
      optional: true,
      type: TransitRealtime.VehiclePosition.VehicleStopStatus,
      enum: true,
      default: :IN_TRANSIT_TO

    field :timestamp, 5, optional: true, type: :uint64

    field :congestion_level, 6,
      optional: true,
      type: TransitRealtime.VehiclePosition.CongestionLevel,
      enum: true

    field :occupancy_status, 9,
      optional: true,
      type: TransitRealtime.VehiclePosition.OccupancyStatus,
      enum: true
  end

  defmodule VehiclePosition.VehicleStopStatus do
    @moduledoc false
    use Protobuf, enum: true, syntax: :proto2

    field :INCOMING_AT, 0
    field :STOPPED_AT, 1
    field :IN_TRANSIT_TO, 2
  end

  defmodule VehiclePosition.CongestionLevel do
    @moduledoc false
    use Protobuf, enum: true, syntax: :proto2

    field :UNKNOWN_CONGESTION_LEVEL, 0
    field :RUNNING_SMOOTHLY, 1
    field :STOP_AND_GO, 2
    field :CONGESTION, 3
    field :SEVERE_CONGESTION, 4
  end

  defmodule VehiclePosition.OccupancyStatus do
    @moduledoc false
    use Protobuf, enum: true, syntax: :proto2

    field :EMPTY, 0
    field :MANY_SEATS_AVAILABLE, 1
    field :FEW_SEATS_AVAILABLE, 2
    field :STANDING_ROOM_ONLY, 3
    field :CRUSHED_STANDING_ROOM_ONLY, 4
    field :FULL, 5
    field :NOT_ACCEPTING_PASSENGERS, 6
  end

  defmodule Position do
    @moduledoc "Geographic position of a vehicle"
    use Protobuf, syntax: :proto2

    field :latitude, 1, required: true, type: :float
    field :longitude, 2, required: true, type: :float
    field :bearing, 3, optional: true, type: :float
    field :odometer, 4, optional: true, type: :double
    field :speed, 5, optional: true, type: :float
  end

  defmodule TripDescriptor do
    @moduledoc "Identifies a trip"
    use Protobuf, syntax: :proto2

    field :trip_id, 1, optional: true, type: :string
    field :route_id, 5, optional: true, type: :string
    field :direction_id, 6, optional: true, type: :uint32
    field :start_time, 2, optional: true, type: :string
    field :start_date, 3, optional: true, type: :string

    field :schedule_relationship, 4,
      optional: true,
      type: TransitRealtime.TripDescriptor.ScheduleRelationship,
      enum: true
  end

  defmodule TripDescriptor.ScheduleRelationship do
    @moduledoc false
    use Protobuf, enum: true, syntax: :proto2

    field :SCHEDULED, 0
    field :ADDED, 1
    field :UNSCHEDULED, 2
    field :CANCELED, 3
  end

  defmodule VehicleDescriptor do
    @moduledoc "Identifies a vehicle"
    use Protobuf, syntax: :proto2

    field :id, 1, optional: true, type: :string
    field :label, 2, optional: true, type: :string
    field :license_plate, 3, optional: true, type: :string
  end

  # Trip Update (stub - not fully implemented)
  defmodule TripUpdate do
    @moduledoc "Real-time trip update (delays, cancellations)"
    use Protobuf, syntax: :proto2

    field :trip, 1, required: true, type: TransitRealtime.TripDescriptor
    field :vehicle, 3, optional: true, type: TransitRealtime.VehicleDescriptor
    field :timestamp, 4, optional: true, type: :uint64
    field :delay, 5, optional: true, type: :int32
  end

  # Alert (stub - not fully implemented)
  defmodule Alert do
    @moduledoc "Service alert"
    use Protobuf, syntax: :proto2

    field :cause, 6,
      optional: true,
      type: TransitRealtime.Alert.Cause,
      enum: true,
      default: :UNKNOWN_CAUSE

    field :effect, 7,
      optional: true,
      type: TransitRealtime.Alert.Effect,
      enum: true,
      default: :UNKNOWN_EFFECT
  end

  defmodule Alert.Cause do
    @moduledoc false
    use Protobuf, enum: true, syntax: :proto2

    field :UNKNOWN_CAUSE, 1
    field :OTHER_CAUSE, 2
    field :TECHNICAL_PROBLEM, 3
    field :STRIKE, 4
    field :DEMONSTRATION, 5
    field :ACCIDENT, 6
    field :HOLIDAY, 7
    field :WEATHER, 8
    field :MAINTENANCE, 9
    field :CONSTRUCTION, 10
    field :POLICE_ACTIVITY, 11
    field :MEDICAL_EMERGENCY, 12
  end

  defmodule Alert.Effect do
    @moduledoc false
    use Protobuf, enum: true, syntax: :proto2

    field :NO_SERVICE, 1
    field :REDUCED_SERVICE, 2
    field :SIGNIFICANT_DELAYS, 3
    field :DETOUR, 4
    field :ADDITIONAL_SERVICE, 5
    field :MODIFIED_SERVICE, 6
    field :OTHER_EFFECT, 7
    field :UNKNOWN_EFFECT, 8
    field :STOP_MOVED, 9
  end
end
