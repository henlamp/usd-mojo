# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Typed Mojo API backed by the official OpenUSD SDK through a C ABI."""
from .errors import UsdError, UsdErrorKind
from .stage import MeshData, MeshSnapshot, Stage, TimeCode, sdk_version
from .values import Vector3, Quaternion, TransformData
from .physics import (
    BodyData,
    MassData,
    MaterialData,
    DriveData,
    JointData,
    read_body,
    read_mass,
    read_material,
    read_joint,
    read_drive,
)

from .value import Value
from .graphics import (
    PrimvarData,
    CameraData,
    read_primvar,
    read_normals,
    read_camera,
)

from .information import AssetPathData, StageInfo, PrimInfo, PrimvarInfo
from .layers import (
    Layer,
    EditTarget,
    save_layers,
    rename_prim,
    remove_prim,
    add_inherit,
    add_specialize,
)
from .metadata import (
    Metadata,
    CompositionArc,
    set_metadata,
    clear_metadata,
    set_layer_field,
    clear_layer_field,
)
from .composition import (
    LoadRule,
    PrimArc,
    population_mask,
    set_population_mask,
    expand_population_mask,
    load_rules,
    set_load_rules,
    mute_layer,
    muted_layers,
    composition_arcs,
    register_plugins,
)

from .schema import SchemaSnapshot, schema_properties
from .scene import (
    visibility,
    purpose,
    world_bounds,
    inherited_primvar,
    instance_transforms,
    instance_mask,
    bound_material,
    skeleton_joints,
    joint_transforms,
    skinning_transforms,
    skinned_points,
)
from .assets import AssetDependency, dependencies, export_usdz

from .snapshots import ChangeSet, poll_changes, SceneSnapshot

from .scene import collection_members
from .clips import clip_sets, clip_set, set_clip_set, clear_clip_set

from .shading import ShaderGraph, ShaderConnection, shader_graph

from .layers import LayerOffset, NamespaceEditor, NamespaceCheck

from .resolver import ResolverContext

from .authoring import (
    AttributeEdit,
    override_prim,
    create_class_prim,
    set_active,
    create_attribute,
    clear_attribute_values,
    clear_value_at,
    block_attribute,
    block_value_at,
    remove_property_opinion,
    set_values,
    set_connections,
    clear_connection_opinions,
    set_relationship_targets,
)

from .arrays import ArraySnapshot, set_array
from .catalog import ValueTypeInfo, value_types

from .validation import (
    ValidationSite,
    ValidationIssue,
    ValidationReport,
    validator_names,
    validate_stage,
)
from .splines import Spline, SplineKnot, SplineExtrapolation, SplineLoop
from .catalog import SchemaTypeInfo, schema_types
from .composition import (
    set_reference_opinions,
    set_payload_opinions,
    set_inherit_opinions,
    set_specialize_opinions,
    clear_arc_opinions,
)
