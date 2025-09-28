import UIKit
import Foundation
import ARKit
import GLTFSceneKit
import Combine

// Responsible for creating Renderables and Nodes
class ArModelBuilder: NSObject {

    func makePlane(anchor: ARPlaneAnchor, flutterAssetFile: String?) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(anchor.extent.x), height: CGFloat(anchor.extent.z))
        //Create material
        let material = SCNMaterial()
        let opacity: CGFloat

        if let textureSourcePath = flutterAssetFile {
            // Use given asset as plane texture
            let key = FlutterDartProject.lookupKey(forAsset: textureSourcePath)
            if let image = UIImage(named: key, in: Bundle.main,compatibleWith: nil){
                // Asset was found so we can use it
                material.diffuse.contents = image
                material.diffuse.wrapS = .repeat
                material.diffuse.wrapT = .repeat
                plane.materials = [material]
                opacity = 1.0
            } else {
                // Use standard planes
                opacity = 0.3
            }
        } else {
            // Use standard planes
            opacity = 0.3
        }

        let planeNode = SCNNode(geometry: plane)
        planeNode.position = SCNVector3Make(anchor.center.x, 0, anchor.center.z)
        // rotate plane by 90 degrees to match the anchor (planes are vertical by default)
        planeNode.eulerAngles.x = -.pi / 2

        planeNode.opacity = opacity

        return planeNode
    }

    func updatePlaneNode(planeNode: SCNNode, anchor: ARPlaneAnchor){
        if let plane = planeNode.geometry as? SCNPlane {
            // Update plane dimensions
            plane.width = CGFloat(anchor.extent.x)
            plane.height = CGFloat(anchor.extent.z)
            // Update texture of planes
            let imageSize: Float = 65 // in mm
            let repeatAmount: Float = 1000 / imageSize //how often per meter we need to repeat the image
            if let gridMaterial = plane.materials.first {
                gridMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(anchor.extent.x * repeatAmount, anchor.extent.z * repeatAmount, 1)
            }
        }
       planeNode.position = SCNVector3Make(anchor.center.x, 0, anchor.center.z)
    }

    // Creates a node from a given gltf2 (.gltf) model in the Flutter assets folder
    func makeNodeFromGltf(name: String, modelPath: String, transformation: Array<NSNumber>?) -> SCNNode? {

        var scene: SCNScene
        let node: SCNNode = SCNNode()

        do {
            let sceneSource = try GLTFSceneSource(named: modelPath)
            scene = try sceneSource.scene()

            for child in scene.rootNode.childNodes {
                child.scale = SCNVector3(1.0,1.0,1.0) // Compensate for the different model dimension definitions in iOS and Android (meters vs. millimeters)
                //child.eulerAngles.z = -.pi // Compensate for the different model coordinate definitions in iOS and Android
                //child.eulerAngles.y = -.pi // Compensate for the different model coordinate definitions in iOS and Android
                node.addChildNode(child.flattenedClone())
            }

            node.name = name
            if let transform = transformation {
                node.transform = deserializeMatrix4(transform)
            }

            return node
        } catch {
            print("\(error.localizedDescription)")
            return nil
        }
    }

    // Creates a node from a given gltf2 (.gltf) model in the Flutter assets folder
    func makeNodeFromFileSystemGltf(name: String, modelPath: String, transformation: Array<NSNumber>?) -> SCNNode? {

        var scene: SCNScene
        let node: SCNNode = SCNNode()

        do {
            let sceneSource = try GLTFSceneSource(path: modelPath)
            scene = try sceneSource.scene()

            for child in scene.rootNode.childNodes {
                child.scale = SCNVector3(0.01,0.01,0.01) // Compensate for the different model dimension definitions in iOS and Android (meters vs. millimeters)
                //child.eulerAngles.z = -.pi // Compensate for the different model coordinate definitions in iOS and Android
                //child.eulerAngles.y = -.pi // Compensate for the different model coordinate definitions in iOS and Android
                node.addChildNode(child.flattenedClone())
            }

            node.name = name
            if let transform = transformation {
                node.transform = deserializeMatrix4(transform)
            }

            return node
        } catch {
            print("\(error.localizedDescription)")
            return nil
        }
    }

    // Creates a node from a given glb model in the app's documents directory
    func makeNodeFromFileSystemGLB(name: String, modelPath: String, transformation: Array<NSNumber>?) -> SCNNode? {

        var scene: SCNScene
        let node: SCNNode = SCNNode()

        do {
            let sceneSource = try GLTFSceneSource(path: modelPath)
            scene = try sceneSource.scene()

            for child in scene.rootNode.childNodes {
                child.scale = SCNVector3(0.01,0.01,0.01) // Compensate for the different model dimension definitions in iOS and Android (meters vs. millimeters)
                //child.eulerAngles.z = -.pi // Compensate for the different model coordinate definitions in iOS and Android
                //child.eulerAngles.y = -.pi // Compensate for the different model coordinate definitions in iOS and Android
                node.addChildNode(child.flattenedClone())
            }

            node.name = name
            if let transform = transformation {
                node.transform = deserializeMatrix4(transform)
            }

            return node
        } catch {
            print("\(error.localizedDescription)")
            return nil
        }
    }

    // Creates a node form a given glb model path
    func makeNodeFromWebGlb1(name: String, modelURL: String, transformation: Array<NSNumber>?) -> Future<SCNNode?, Never> {

        return Future {promise in
            var node: SCNNode? = SCNNode()

            let handler: (URL?, URLResponse?, Error?) -> Void = {(url: URL?, urlResponse: URLResponse?, error: Error?) -> Void in
                // If response code is not 200, link was invalid, so return
                if ((urlResponse as? HTTPURLResponse)?.statusCode != 200) {
                    print("makeNodeFromWebGltf received non-200 response code")
                    node = nil
                    promise(.success(node))
                } else {
                    guard let fileURL = url else { return }
                    do {
                        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                        let documentsDirectory = paths[0]
                        let targetURL = documentsDirectory.appendingPathComponent(urlResponse!.url!.lastPathComponent)

                        try? FileManager.default.removeItem(at: targetURL) //remove item if it's already there
                        try FileManager.default.copyItem(at: fileURL, to: targetURL)

                        do {
                            let sceneSource = GLTFSceneSource(url: targetURL)
                            let scene = try sceneSource.scene()

                            for child in scene.rootNode.childNodes {
                                child.scale = SCNVector3(1.0,1.0,1.0) // Compensate for the different model dimension definitions in iOS and Android (meters vs. millimeters)
                                //child.eulerAngles.z = -.pi // Compensate for the different model coordinate definitions in iOS and Android
                                //child.eulerAngles.y = -.pi // Compensate for the different model coordinate definitions in iOS and Android
                                child.light = SCNLight()
                                    child.light?.type = SCNLight.LightType.directional
                                    child.light?.color = UIColor.white
                                    child.light?.castsShadow = true
                                    child.light?.automaticallyAdjustsShadowProjection = true
                                    child.light?.shadowSampleCount = 64
                                    child.light?.shadowRadius = 16
                                    child.light?.shadowMode = .deferred
                                    child.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
                                    child.light?.shadowColor = UIColor.black.withAlphaComponent(0.75)
                                node?.addChildNode(child)
                            }

                            node?.name = name
                            if let transform = transformation {
                                node?.transform = deserializeMatrix4(transform)
                            }
                            /*node?.scale = worldScale
                            node?.position = worldPosition
                            node?.worldOrientation = worldRotation*/

                        } catch {
                            print("\(error.localizedDescription)")
                            node = nil
                        }

                        // Delete file to avoid cluttering device storage (at some point, caching can be included)
                        try FileManager.default.removeItem(at: targetURL)

                        promise(.success(node))
                    } catch {
                        node = nil
                        promise(.success(node))
                    }
                }

            }


            let downloadTask = URLSession.shared.downloadTask(with: URL(string: modelURL)!, completionHandler: handler)

            downloadTask.resume()

        }

    }
func makeNodeFromWebGlb2(name: String, modelURL: String, transformation: [NSNumber]?) -> Future<SCNNode?, Never> {

    return Future { promise in
        var node: SCNNode? = SCNNode()

        let handler: (URL?, URLResponse?, Error?) -> Void = { (url: URL?, urlResponse: URLResponse?, error: Error?) in
            if ((urlResponse as? HTTPURLResponse)?.statusCode != 200) {
                print("makeNodeFromWebGltf received non-200 response code")
                node = nil
                promise(.success(node))
                return
            }

            guard let fileURL = url else { return }
            do {
                let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                let documentsDirectory = paths[0]
                let targetURL = documentsDirectory.appendingPathComponent(urlResponse!.url!.lastPathComponent)

                try? FileManager.default.removeItem(at: targetURL)
                try FileManager.default.copyItem(at: fileURL, to: targetURL)

                do {
                    let sceneSource = GLTFSceneSource(url: targetURL)
                    let scene = try sceneSource.scene()

                    for child in scene.rootNode.childNodes {
                        child.scale = SCNVector3(1.0, 1.0, 1.0)
                        node?.addChildNode(child)
                    }

                    node?.name = name
                    if let transform = transformation {
                        node?.transform = deserializeMatrix4(transform)
                    }

                    // =========================
                    // Add Shadow on 3D Model
                    // =========================
                    let floorPlane = SCNFloor()
                    let groundPlaneNode = SCNNode()
                    let groundMaterial = SCNMaterial()
                    groundMaterial.lightingModel = .constant
                    groundMaterial.writesToDepthBuffer = true
                    groundMaterial.colorBufferWriteMask = []
                    groundMaterial.isDoubleSided = true
                    floorPlane.materials = [groundMaterial]
                    groundPlaneNode.geometry = floorPlane
                    node?.addChildNode(groundPlaneNode)

                    // Ambient Light
                    let ambientLight = SCNNode()
                    ambientLight.light = SCNLight()
                    ambientLight.light?.shadowMode = .deferred
                    ambientLight.light?.color = UIColor.white
                    ambientLight.light?.type = .ambient
                    ambientLight.position = SCNVector3(x: 0, y: 5, z: 0)
                    node?.addChildNode(ambientLight)

                    // Directional Light with Shadows
                    let directionalLightNode = SCNNode()
                    directionalLightNode.light = SCNLight()
                    directionalLightNode.light?.type = .directional
                    directionalLightNode.light?.color = UIColor.white
                    directionalLightNode.light?.castsShadow = true
                    directionalLightNode.light?.automaticallyAdjustsShadowProjection = true
                    directionalLightNode.light?.shadowSampleCount = 64
                    directionalLightNode.light?.shadowRadius = 32
                    directionalLightNode.light?.shadowMode = .deferred
                    directionalLightNode.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
                    directionalLightNode.light?.shadowColor = UIColor.black.withAlphaComponent(0.5)
                    directionalLightNode.position = SCNVector3(x: 0, y: 5, z: 5)
                    directionalLightNode.eulerAngles = SCNVector3(-Float.pi / 4, 0, 0)
                    node?.addChildNode(directionalLightNode)

                } catch {
                    print("\(error.localizedDescription)")
                    node = nil
                }

                try FileManager.default.removeItem(at: targetURL)
                promise(.success(node))

            } catch {
                node = nil
                promise(.success(node))
            }
        }

        let downloadTask = URLSession.shared.downloadTask(with: URL(string: modelURL)!, completionHandler: handler)
        downloadTask.resume()
    }
}

    func makeNodeFromWebGlb1223(
    name: String,
    modelURL: String,
    transformation: [NSNumber]?,
    targetSize: Float? = nil
    ) -> Future<SCNNode?, Never> {

        return Future { promise in
            var node: SCNNode? = SCNNode()

            let handler: (URL?, URLResponse?, Error?) -> Void = { (url: URL?, urlResponse: URLResponse?, error: Error?) in
                if ((urlResponse as? HTTPURLResponse)?.statusCode != 200) {
                    print("makeNodeFromWebGlb received non-200 response code")
                    node = nil
                    promise(.success(node))
                    return
                }

                guard let fileURL = url else { return }
                do {
                    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                    let documentsDirectory = paths[0]
                    let targetURL = documentsDirectory.appendingPathComponent(urlResponse!.url!.lastPathComponent)

                    try? FileManager.default.removeItem(at: targetURL)
                    try FileManager.default.copyItem(at: fileURL, to: targetURL)

                    do {
                        let sceneSource = GLTFSceneSource(url: targetURL)
                        let scene = try sceneSource.scene()

                        // -------------------------
                        // Create model node
                        // -------------------------
                        node = SCNNode()
                        node?.name = name

                        for child in scene.rootNode.childNodes {
                            node?.addChildNode(child)
                        }

                        if let unwrappedNode = node, let transform = transformation {
                            let (scale, position, rotation) = deserializeMatrix4s(transform, scaleFactor: 0.65)
                            unwrappedNode.pivot = SCNMatrix4Identity
                            unwrappedNode.position = position
                            unwrappedNode.scale = scale
                            unwrappedNode.orientation = rotation
                        }

                        // -------------------------
                        // Apply uniform scaling if targetSize is provided
                        // -------------------------
                        if let unwrappedNode = node, let targetSize = targetSize {
                            self.scaleNodeToUniformSize(unwrappedNode, targetSize: targetSize)

                            let (minVec, maxVec) = unwrappedNode.boundingBox
                            let width  = (maxVec.x - minVec.x) * unwrappedNode.scale.x
                            let height = (maxVec.y - minVec.y) * unwrappedNode.scale.y
                            let length = (maxVec.z - minVec.z) * unwrappedNode.scale.z
                            print("Scaled real-world size: W:\(width)m, H:\(height)m, L:\(length)m")
                        }

                    } catch {
                        print("\(error.localizedDescription)")
                        node = nil
                    }

                    try FileManager.default.removeItem(at: targetURL)
                    promise(.success(node))

                } catch {
                    node = nil
                    promise(.success(node))
                }
            }

            let downloadTask = URLSession.shared.downloadTask(
                with: URL(string: modelURL)!,
                completionHandler: handler
            )
            downloadTask.resume()
        }
    }
func makeNodeFromWebGlb(
    name: String,
    modelURL: String,
    transformation: [NSNumber]?,
    targetSize: Float? = nil,
    autoScale: Bool = false,
    maxSize: Float = 2.0,   
) -> Future<SCNNode?, Never> {

    return Future { promise in
        var node: SCNNode? = SCNNode()

        let handler: (URL?, URLResponse?, Error?) -> Void = { (url: URL?, urlResponse: URLResponse?, error: Error?) in
            if ((urlResponse as? HTTPURLResponse)?.statusCode != 200) {
                print("makeNodeFromWebGlb received non-200 response code")
                node = nil
                promise(.success(node))
                return
            }

            guard let fileURL = url else { return }
            do {
                let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                let documentsDirectory = paths[0]
                let targetURL = documentsDirectory.appendingPathComponent(urlResponse!.url!.lastPathComponent)

                try? FileManager.default.removeItem(at: targetURL)
                try FileManager.default.copyItem(at: fileURL, to: targetURL)

                do {
                    let sceneSource = GLTFSceneSource(url: targetURL)
                    let scene = try sceneSource.scene()

                    // -------------------------
                    // Create model node
                    // -------------------------
                    let parent = SCNNode()
                    parent.name = name

                    for child in scene.rootNode.childNodes {
                        parent.addChildNode(child)
                    }

                    // -------------------------
                    // 1) طبّق التحويل القادم من Flutter (بدون أي factor إضافي)
                    // -------------------------
                    if let transform = transformation {
                        let (scale, position, rotation) = deserializeMatrix4s(transform)
                        parent.pivot = SCNMatrix4Identity
                        parent.position = position
                        parent.scale = scale          // non-uniform from matrix
                        parent.orientation = rotation
                    }

                    // -------------------------
                    // 2) autoScale مطابق لـ Android: احسب largestDim من الهيريكي
                    //    (قبل أي targetSize)، واضرب scale الحالي في factor موحّد
                    // -------------------------
                    if autoScale {
                        // احفظ الـ scale الحالي
                        let originalScale = parent.scale

                        // مؤقتًا set scale = (1,1,1) لحساب أبعاد الموديل الأصلية (بدون تأثير scale الحالي)
                        parent.scale = SCNVector3(1,1,1)

                        if let (bbMin, bbMax) = hierarchyBoundingBox(inParentSpace: parent) {
                            let width  = bbMax.x - bbMin.x
                            let height = bbMax.y - bbMin.y
                            let depth  = bbMax.z - bbMin.z
                            let largestDim = max(width, max(height, depth))

                            var autoScaleFactor: Float = 1.0
                            if largestDim > maxSize {
                                autoScaleFactor = maxSize / largestDim
                                print("Auto-scale factor = \(autoScaleFactor)")
                            }

                            // أعد scale الأصلي * autoScaleFactor (uniform)
                            parent.scale = SCNVector3(
                                originalScale.x * autoScaleFactor,
                                originalScale.y * autoScaleFactor,
                                originalScale.z * autoScaleFactor
                            )
                        } else {
                            // لم نجد هندسة، أعد scale الأصلي
                            parent.scale = originalScale
                        }
                    }

                    // -------------------------
                    // 3) خيار إضافي: targetSize (إن رغبت الاحتفاظ به)
                    //    هذا يطبّق scale موحّد للوصول إلى أبعاد معيّنة
                    // -------------------------
                    if let targetSize = targetSize {
                        // احسب الأبعاد الحالية بعد كل ما سبق
                        if let (bbMin, bbMax) = hierarchyBoundingBox(inParentSpace: parent) {
                            let width  = (bbMax.x - bbMin.x) * parent.scale.x
                            let height = (bbMax.y - bbMin.y) * parent.scale.y
                            let depth  = (bbMax.z - bbMin.z) * parent.scale.z
                            let largest = max(width, max(height, depth))
                            if largest > 0 {
                                let factor = targetSize / largest
                                parent.scale = SCNVector3(parent.scale.x * factor,
                                                          parent.scale.y * factor,
                                                          parent.scale.z * factor)
                                print("Scaled to target size. Real size W:\(width*factor)m, H:\(height*factor)m, D:\(depth*factor)m")
                            }
                        }
                    }

                    node = parent

                } catch {
                    print("\(error.localizedDescription)")
                    node = nil
                }

                try FileManager.default.removeItem(at: targetURL)
                promise(.success(node))

            } catch {
                node = nil
                promise(.success(node))
            }
        }

        let downloadTask = URLSession.shared.downloadTask(
            with: URL(string: modelURL)!,
            completionHandler: handler
        )
        downloadTask.resume()
    }
}

func scaleNodeToUniformSize(_ node: SCNNode, targetSize: Float) {
    let (minVec, maxVec) = node.boundingBox
    let width = maxVec.x - minVec.x
    let height = maxVec.y - minVec.y
    let length = maxVec.z - minVec.z

    // أكبر بعد (أبعاد النموذج)
    let maxDimension = max(width, max(height, length))

    // نسبة المقياس المطلوبة ليصبح الحجم النهائي = targetSize
    let scale = targetSize / maxDimension

    node.scale = SCNVector3(scale, scale, scale)
}
}
