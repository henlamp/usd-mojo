from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import (
    Stage,
    Vector3,
    Quaternion,
    read_body,
    read_mass,
    read_material,
    read_joint,
)


def main() raises:
    var folder = argv()[1]
    var stage = Stage(folder + "/physics_box.usda")
    var body = read_body(stage, "/World/Box")
    assert_true(body.enabled and not body.kinematic)
    assert_equal(body.mass.mass, Float64(1))
    assert_true(not body.mass.has_center_of_mass)
    assert_equal(stage.read_vector3("/World/Box", "offset"), Vector3(1, 2, 3))
    assert_equal(
        stage.read_quaternion("/World/Box", "orientation"), Quaternion.identity
    )
    var matrix = stage.read_matrix4("/World/Box", "matrix")
    assert_equal(matrix[0], Float64(1))
    assert_equal(matrix[12], Float64(0))
    var weights = stage.read_float_array("/World/Box", "weights")
    assert_equal(weights[1], Float64(0.5))
    var indices = stage.read_int_array("/World/Box", "indices")
    assert_equal(indices[1], Int32(-2))
    var directions = stage.read_vector3_array("/World/Box", "directions")
    assert_equal(directions[1], Vector3(0, 1, 0))
    var transform = stage.transform("/World/Box/Collider")
    assert_equal(transform.position.z, Float64(2))
    assert_equal(transform.scale.x, Float64(0.25))
    assert_equal(
        stage.closest_schema("/World/Box/Collider", "PhysicsRigidBodyAPI"),
        String("/World/Box"),
    )
    var material = read_material(stage, "/World/Box/Collider")
    assert_equal(material.path, String("/World/Material"))
    assert_true(material.specified)
    assert_true(abs(material.dynamic_friction - 0.6) < 1e-6)
    var fixed = read_joint(stage, "/World/DisabledFixed")
    assert_true(not fixed.enabled)
    assert_equal(fixed.body1, String("/World/Box"))
    var chain = Stage(folder + "/physics_chain.usda")
    var joint = read_joint(chain, "/World/Shoulder")
    assert_true(joint.drive.enabled and joint.has_limits)
    assert_equal(joint.body0, String(""))
    assert_equal(joint.body1, String("/World/Arm0"))
    assert_equal(joint.axis, String("Y"))
    assert_equal(joint.upper_limit, Float64(45))
    assert_true(abs(joint.drive.damping - 100 * 3.141592653589793 / 180) < 1e-6)
    var relationships = chain.relationship_names("/World/Shoulder")
    assert_true(len(relationships) >= 2)
    var units = Stage(folder + "/physics_units.usda")
    assert_equal(units.meters_per_unit(), Float64(0.01))
    assert_equal(units.kilograms_per_unit(), Float64(0.001))
    assert_equal(units.up_axis(), String("Y"))
    assert_equal(
        read_body(units, "/World/Referenced/Box").mass.mass, Float64(1000)
    )
    assert_true(not units.is_instance("/World/Referenced"))
    var rejected = False
    try:
        var bad = stage.read_quaternion("/World/Box", "offset")
        _ = bad
    except:
        rejected = True
    assert_true(rejected)
    print(
        "PASS typed vectors/quaternions/arrays, USD physics, inherited"
        " material, joint relationships and units"
    )
