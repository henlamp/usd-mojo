# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Typed UsdPhysics schema values, retaining stage distance/mass units and degrees.

Mass/density zero and inertia zero retain USD's request for derived values.
Schema readers do not integrate physics or select solver-specific defaults.
"""
from std.math import isfinite
from .errors import UsdError
from .stage import Stage, TimeCode
from .values import Vector3, Quaternion


@fieldwise_init
struct MassData(ImplicitlyCopyable):
    var mass: Float64
    var density: Float64
    var center_of_mass: Vector3
    var has_center_of_mass: Bool
    var diagonal_inertia: Vector3
    var principal_axes: Quaternion


@fieldwise_init
struct BodyData(ImplicitlyCopyable):
    var enabled: Bool
    var kinematic: Bool
    var mass: MassData
    var velocity: Vector3
    var angular_velocity: Vector3


@fieldwise_init
struct MaterialData(Copyable):
    var path: String
    var specified: Bool
    var static_friction: Float64
    var dynamic_friction: Float64
    var restitution: Float64
    var density: Float64


@fieldwise_init
struct DriveData(Copyable):
    var enabled: Bool
    var mode: String
    var stiffness: Float64
    var damping: Float64
    var maximum_force: Float64
    var target_position: Float64
    var target_velocity: Float64


@fieldwise_init
struct JointData(Copyable):
    var kind: String
    var enabled: Bool
    var collision_enabled: Bool
    var body0: String
    var body1: String
    var local_position0: Vector3
    var local_rotation0: Quaternion
    var local_position1: Vector3
    var local_rotation1: Quaternion
    var axis: String
    var lower_limit: Float64
    var upper_limit: Float64
    var has_limits: Bool
    var drive: DriveData


def read_mass(
    stage: Stage, var path: String, time: TimeCode = .default
) raises UsdError -> MassData:
    if not stage.has_schema(path, "PhysicsMassAPI"):
        return MassData(0, 0, .zero, False, .zero, .identity)
    var com = stage.read_vector3(path, "physics:centerOfMass", time)
    var specified = isfinite(com.x) and isfinite(com.y) and isfinite(com.z)
    return MassData(
        stage.read_float(path, "physics:mass", time),
        stage.read_float(path, "physics:density", time),
        com,
        specified,
        stage.read_vector3(path, "physics:diagonalInertia", time),
        stage.read_quaternion(path, "physics:principalAxes", time),
    )


def read_body(
    stage: Stage, var path: String, time: TimeCode = .default
) raises UsdError -> BodyData:
    if not stage.has_schema(path, "PhysicsRigidBodyAPI"):
        raise UsdError(.type_mismatch, "Prim has no PhysicsRigidBodyAPI")
    return BodyData(
        stage.read_bool(path, "physics:rigidBodyEnabled", time),
        stage.read_bool(path, "physics:kinematicEnabled", time),
        read_mass(stage, path, time),
        stage.read_vector3(path, "physics:velocity", time),
        stage.read_vector3(path, "physics:angularVelocity", time),
    )


def read_material(
    stage: Stage, var collider_path: String, time: TimeCode = .default
) raises UsdError -> MaterialData:
    var path = stage.physics_material_path(collider_path)
    if path.byte_length() == 0 or not stage.has_schema(
        path, "PhysicsMaterialAPI"
    ):
        return MaterialData(path, False, 0.5, 0.5, 0, 0)
    return MaterialData(
        path,
        True,
        stage.read_float(path, "physics:staticFriction", time),
        stage.read_float(path, "physics:dynamicFriction", time),
        stage.read_float(path, "physics:restitution", time),
        stage.read_float(path, "physics:density", time),
    )


def read_drive(
    stage: Stage, var path: String, instance: String, time: TimeCode = .default
) raises UsdError -> DriveData:
    if not stage.has_schema(path, String("PhysicsDriveAPI:", instance)):
        return DriveData(False, "force", 0, 0, 0, 0, 0)
    var prefix = String("drive:", instance, ":physics:")
    return DriveData(
        True,
        stage.read_text(path, prefix + "type", time),
        stage.read_float(path, prefix + "stiffness", time),
        stage.read_float(path, prefix + "damping", time),
        stage.read_float(path, prefix + "maxForce", time),
        stage.read_float(path, prefix + "targetPosition", time),
        stage.read_float(path, prefix + "targetVelocity", time),
    )


def _endpoint(
    stage: Stage, var path: String, var name: String
) raises UsdError -> String:
    var targets = stage.relationship_targets(path, name)
    if len(targets) > 1:
        raise UsdError(
            .invalid_data, "A USD joint endpoint must have zero or one target"
        )
    return targets[0] if len(targets) else String("")


def read_joint(
    stage: Stage, var path: String, time: TimeCode = .default
) raises UsdError -> JointData:
    var kind = stage.prim_type(path)
    if (
        kind != "PhysicsFixedJoint"
        and kind != "PhysicsRevoluteJoint"
        and kind != "PhysicsPrismaticJoint"
    ):
        raise UsdError(
            .invalid_argument,
            "Typed joint reader supports fixed, revolute and prismatic joints",
        )
    var axis = String("X")
    var lower = Float64(0)
    var upper = Float64(0)
    var limits = False
    var drive = DriveData(False, "force", 0, 0, 0, 0, 0)
    if kind != "PhysicsFixedJoint":
        axis = stage.read_text(path, "physics:axis", time)
        lower = stage.read_float(path, "physics:lowerLimit", time)
        upper = stage.read_float(path, "physics:upperLimit", time)
        limits = isfinite(lower) or isfinite(upper)
        drive = read_drive(
            stage,
            path,
            "angular" if kind == "PhysicsRevoluteJoint" else "linear",
            time,
        )
    return JointData(
        kind,
        stage.read_bool(path, "physics:jointEnabled", time),
        stage.read_bool(path, "physics:collisionEnabled", time),
        _endpoint(stage, path, "physics:body0"),
        _endpoint(stage, path, "physics:body1"),
        stage.read_vector3(path, "physics:localPos0", time),
        stage.read_quaternion(path, "physics:localRot0", time),
        stage.read_vector3(path, "physics:localPos1", time),
        stage.read_quaternion(path, "physics:localRot1", time),
        axis,
        lower,
        upper,
        limits,
        drive^,
    )
