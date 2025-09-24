// The code in this file is adapted from Oleksandr Leuschenko' ARKit Flutter Plugin (https://github.com/olexale/arkit_flutter_plugin)

import ARKit
import GLTFSceneKit
import Foundation
import SceneKit
import simd // استيراد simd للتعامل مع الرياضيات المتقدمة للمصفوفات والكواتيرنيون

func deserializeVector3(_ coords: Array<Double>) -> SCNVector3 {
    let point = SCNVector3(coords[0], coords[1], coords[2])
    return point
}

func deserializeVector4(_ coords: Array<Double>) -> SCNVector4 {
    let point = SCNVector4(coords[0], coords[1], coords[2], coords[3])
    return point
}

func deserializeMatrix4(_ c: Array<NSNumber>) -> SCNMatrix4 {
    let coords = c.map({ Float(truncating: $0 )})
    let matrix = SCNMatrix4(m11: coords[0], m12: coords[1],m13: coords[2], m14: coords[3], m21: coords[4], m22: coords[5], m23: coords[6], m24: coords[7], m31: coords[8], m32: coords[9], m33: coords[10], m34: coords[11], m41: coords[12], m42: coords[13], m43: coords[14], m44: coords[15])
    return matrix
}


func deserializeMatrix4s2(_ c: Array<NSNumber>) -> (scale: SCNVector3, position: SCNVector3, rotation: SCNQuaternion) {
    let m = c.map({ Float(truncating: $0) })

    // 1. استخراج الحجم (Scale)
    // يتم حساب الحجم عن طريق حساب طول متجهات الأعمدة الثلاثة الأولى في المصفوفة
    let scaleX = sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2])
    let scaleY = sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6])
    let scaleZ = sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10])
    let scale = SCNVector3(scaleX, scaleY, scaleZ)

    // 2. استخراج الموضع (Position/Translation)
    // الموضع هو ببساطة العمود الأخير من المصفوفة
    let position = SCNVector3(m[12], m[13], m[14])

    // 3. استخراج الدوران (Rotation)
    // أولاً، ننشئ مصفوفة دوران 3x3 نقية عن طريق قسمة عناصر المصفوفة على الحجم
    let rs1 = SIMD3<Float>(m[0] / scaleX, m[1] / scaleX, m[2] / scaleX)
    let rs2 = SIMD3<Float>(m[4] / scaleY, m[5] / scaleY, m[6] / scaleY)
    let rs3 = SIMD3<Float>(m[8] / scaleZ, m[9] / scaleZ, m[10] / scaleZ)
    let rotationMatrix = simd_float3x3(rs1, rs2, rs3)

    // تحويل مصفوفة الدوران إلى كواتيرنيون (Quaternion)
    let inputQuaternion = simd_quatf(rotationMatrix)

    // 4. تطبيق تصحيح نظام الإحداثيات (نفس منطق Kotlin تمامًا)
    // إنشاء كواتيرنيون لدوران 180 درجة (pi) حول محور Y
    let correctionY = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
    // إنشاء كواتيرنيون لدوران 180 درجة (pi) حول محور Z
    let correctionZ = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))

    // ضرب الكواتيرنيونات لتطبيق التصحيح. الترتيب مهم.
    let finalSimdQuat = inputQuaternion * correctionY * correctionZ

    // تحويل الناتج النهائي إلى SCNQuaternion
    let finalRotation = SCNQuaternion(finalSimdQuat.vector.x, finalSimdQuat.vector.y, finalSimdQuat.vector.z, finalSimdQuat.vector.w)

    return (scale, position, finalRotation)
}
func deserializeMatrix4s1(_ c: [NSNumber]) -> (scale: SCNVector3, position: SCNVector3, rotation: SCNQuaternion) {
    let coords = c.map({ Float(truncating: $0) })

    // تحويل إلى SCNMatrix4
    let matrix = SCNMatrix4(
        m11: coords[0], m12: coords[1], m13: coords[2], m14: coords[3],
        m21: coords[4], m22: coords[5], m23: coords[6], m24: coords[7],
        m31: coords[8], m32: coords[9], m33: coords[10], m34: coords[11],
        m41: coords[12], m42: coords[13], m43: coords[14], m44: coords[15]
    )

    // استخراج الـ scale
    let scaleX = sqrt(matrix.m11 * matrix.m11 + matrix.m12 * matrix.m12 + matrix.m13 * matrix.m13)
    let scaleY = sqrt(matrix.m21 * matrix.m21 + matrix.m22 * matrix.m22 + matrix.m23 * matrix.m23)
    let scaleZ = sqrt(matrix.m31 * matrix.m31 + matrix.m32 * matrix.m32 + matrix.m33 * matrix.m33)

    // استخراج الـ position
    let position = SCNVector3(matrix.m41, matrix.m42, matrix.m43)

    // استخراج rotation (SCNQuaternion)
    let rotationMatrix = SCNMatrix4(
        m11: matrix.m11/scaleX, m12: matrix.m12/scaleX, m13: matrix.m13/scaleX, m14: 0,
        m21: matrix.m21/scaleY, m22: matrix.m22/scaleY, m23: matrix.m23/scaleY, m24: 0,
        m31: matrix.m31/scaleZ, m32: matrix.m32/scaleZ, m33: matrix.m33/scaleZ, m34: 0,
        m41: 0, m42: 0, m43: 0, m44: 1
    )

    let trace = rotationMatrix.m11 + rotationMatrix.m22 + rotationMatrix.m33
    var q = SCNQuaternion()

    if trace > 0 {
        let s = sqrt(trace + 1.0) * 2
        q.w = s * 0.25
        q.x = (rotationMatrix.m32 - rotationMatrix.m23) / s
        q.y = (rotationMatrix.m13 - rotationMatrix.m31) / s
        q.z = (rotationMatrix.m21 - rotationMatrix.m12) / s
    } else if (rotationMatrix.m11 > rotationMatrix.m22 && rotationMatrix.m11 > rotationMatrix.m33) {
        let s = sqrt(1.0 + rotationMatrix.m11 - rotationMatrix.m22 - rotationMatrix.m33) * 2
        q.w = (rotationMatrix.m32 - rotationMatrix.m23) / s
        q.x = s * 0.25
        q.y = (rotationMatrix.m12 + rotationMatrix.m21) / s
        q.z = (rotationMatrix.m13 + rotationMatrix.m31) / s
    } else if rotationMatrix.m22 > rotationMatrix.m33 {
        let s = sqrt(1.0 + rotationMatrix.m22 - rotationMatrix.m11 - rotationMatrix.m33) * 2
        q.w = (rotationMatrix.m13 - rotationMatrix.m31) / s
        q.x = (rotationMatrix.m12 + rotationMatrix.m21) / s
        q.y = s * 0.25
        q.z = (rotationMatrix.m23 + rotationMatrix.m32) / s
    } else {
        let s = sqrt(1.0 + rotationMatrix.m33 - rotationMatrix.m11 - rotationMatrix.m22) * 2
        q.w = (rotationMatrix.m21 - rotationMatrix.m12) / s
        q.x = (rotationMatrix.m13 + rotationMatrix.m31) / s
        q.y = (rotationMatrix.m23 + rotationMatrix.m32) / s
        q.z = s * 0.25
    }

    return (SCNVector3(scaleX, scaleY, scaleZ), position, q)
}

func deserializeMatrix4s(_ c: [NSNumber], scaleFactor: Float = 0.8) -> (scale: SCNVector3, position: SCNVector3, rotation: SCNQuaternion) {
    let coords = c.map({ Float(truncating: $0) })

    // تحويل إلى SCNMatrix4
    let matrix = SCNMatrix4(
        m11: coords[0], m12: coords[1], m13: coords[2], m14: coords[3],
        m21: coords[4], m22: coords[5], m23: coords[6], m24: coords[7],
        m31: coords[8], m32: coords[9], m33: coords[10], m34: coords[11],
        m41: coords[12], m42: coords[13], m43: coords[14], m44: coords[15]
    )

    // استخراج الـ scale مع معامل تصغير بسيط
    let scaleX = sqrt(matrix.m11 * matrix.m11 + matrix.m12 * matrix.m12 + matrix.m13 * matrix.m13) * scaleFactor
    let scaleY = sqrt(matrix.m21 * matrix.m21 + matrix.m22 * matrix.m22 + matrix.m23 * matrix.m23) * scaleFactor
    let scaleZ = sqrt(matrix.m31 * matrix.m31 + matrix.m32 * matrix.m32 + matrix.m33 * matrix.m33) * scaleFactor

    // استخراج الـ position
    let position = SCNVector3(matrix.m41, matrix.m42, matrix.m43)

    // استخراج rotation (SCNQuaternion)
    let rotationMatrix = SCNMatrix4(
        m11: matrix.m11/scaleX, m12: matrix.m12/scaleX, m13: matrix.m13/scaleX, m14: 0,
        m21: matrix.m21/scaleY, m22: matrix.m22/scaleY, m23: matrix.m23/scaleY, m24: 0,
        m31: matrix.m31/scaleZ, m32: matrix.m32/scaleZ, m33: matrix.m33/scaleZ, m34: 0,
        m41: 0, m42: 0, m43: 0, m44: 1
    )

    let trace = rotationMatrix.m11 + rotationMatrix.m22 + rotationMatrix.m33
    var q = SCNQuaternion()

    if trace > 0 {
        let s = sqrt(trace + 1.0) * 2
        q.w = s * 0.25
        q.x = (rotationMatrix.m32 - rotationMatrix.m23) / s
        q.y = (rotationMatrix.m13 - rotationMatrix.m31) / s
        q.z = (rotationMatrix.m21 - rotationMatrix.m12) / s
    } else if (rotationMatrix.m11 > rotationMatrix.m22 && rotationMatrix.m11 > rotationMatrix.m33) {
        let s = sqrt(1.0 + rotationMatrix.m11 - rotationMatrix.m22 - rotationMatrix.m33) * 2
        q.w = (rotationMatrix.m32 - rotationMatrix.m23) / s
        q.x = s * 0.25
        q.y = (rotationMatrix.m12 + rotationMatrix.m21) / s
        q.z = (rotationMatrix.m13 + rotationMatrix.m31) / s
    } else if rotationMatrix.m22 > rotationMatrix.m33 {
        let s = sqrt(1.0 + rotationMatrix.m22 - rotationMatrix.m11 - rotationMatrix.m33) * 2
        q.w = (rotationMatrix.m13 - rotationMatrix.m31) / s
        q.x = (rotationMatrix.m12 + rotationMatrix.m21) / s
        q.y = s * 0.25
        q.z = (rotationMatrix.m23 + rotationMatrix.m32) / s
    } else {
        let s = sqrt(1.0 + rotationMatrix.m33 - rotationMatrix.m11 - rotationMatrix.m22) * 2
        q.w = (rotationMatrix.m21 - rotationMatrix.m12) / s
        q.x = (rotationMatrix.m13 + rotationMatrix.m31) / s
        q.y = (rotationMatrix.m23 + rotationMatrix.m32) / s
        q.z = s * 0.25
    }

    return (SCNVector3(scaleX, scaleY, scaleZ), position, q)
}
