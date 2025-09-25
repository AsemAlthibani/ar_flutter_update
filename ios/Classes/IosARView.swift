import Flutter
import UIKit
import Foundation
import ARKit
import Combine
import ARCoreCloudAnchors

class IosARView: NSObject, FlutterPlatformView, ARSCNViewDelegate, UIGestureRecognizerDelegate, ARSessionDelegate {
    let sceneView: ARSCNView
    let coachingView: ARCoachingOverlayView
    let sessionManagerChannel: FlutterMethodChannel
    let objectManagerChannel: FlutterMethodChannel
    let anchorManagerChannel: FlutterMethodChannel
    var showPlanes = false
    var planeCount = 0
    var customPlaneTexturePath: String? = nil
    private var trackedPlanes = [UUID: (SCNNode, SCNNode)]()
    let modelBuilder = ArModelBuilder()
    
    var cancellableCollection = Set<AnyCancellable>() //Used to store all cancellables in (needed for working with Futures)
    var anchorCollection = [String: ARAnchor]() //Used to bookkeep all anchors created by Flutter calls
    
    private var cloudAnchorHandler: CloudAnchorHandler? = nil
    private var arcoreSession: GARSession? = nil
    private var arcoreMode: Bool = false
    private var configuration: ARWorldTrackingConfiguration!
    private var tappedPlaneAnchorAlignment = ARPlaneAnchor.Alignment.horizontal // default alignment
    
    private var panStartLocation: CGPoint?
    private var panCurrentLocation: CGPoint?
    private var panCurrentVelocity: CGPoint?
    private var panCurrentTranslation: CGPoint?
    private var rotationStartLocation: CGPoint?
    private var rotation: CGFloat?
    private var rotationVelocity: CGFloat?
    private var panningNode: SCNNode?
    private var panningNodeCurrentWorldLocation: SCNVector3?
    // ===== Quality Ring (iOS) =====
    private var qualityRingParent: SCNNode? = nil
    private var qualitySegments: Int = 16
    private var qualityStates: [Int] = Array(repeating: 0, count: 16) // 0=UNSEEN, 1=SEEN_OK, 2=GOOD
    private var ringRadiusMeters: Float = 0.6
    private var ringHeightMeters: Float = 0.25
    private var ringColumnWidth: Float = 0.05
    private var ringPending: Bool = false
    private var qualityRingEnabled: Bool = true
    private var hostingTriggered: Bool = false
    private var hostingAnchorName: String? = nil

    // مواد الأعمدة
    private lazy var matRed: SCNMaterial = { let m = SCNMaterial(); m.diffuse.contents = UIColor.red; return m }()
    private lazy var matYellow: SCNMaterial = { let m = SCNMaterial(); m.diffuse.contents = UIColor.yellow; return m }()
    private lazy var matGreen: SCNMaterial = { let m = SCNMaterial(); m.diffuse.contents = UIColor.green; return m }()

    // Depth occlusion from Flutter (boolean)
    private var depthOcclusionMode: Bool = false
    private var resolveQueue: [String] = []
    private var resolving: Bool = false
    private var pendingResolveId: String? = nil
    private var currentResolveRetryCount: Int = 0
    private let maxResolveRetriesDefault: Int = 5
    private let baseResolveDelayMsDefault: Int = 750



    enum AnchorQuality: Int {
    case insufficient = 0
    case sufficient = 1
    case excellent = 2
}
    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        self.sceneView = ARSCNView(frame: frame)
        self.coachingView = ARCoachingOverlayView(frame: frame)
        self.sessionManagerChannel = FlutterMethodChannel(name: "arsession_\(viewId)", binaryMessenger: messenger)
        self.objectManagerChannel = FlutterMethodChannel(name: "arobjects_\(viewId)", binaryMessenger: messenger)
        self.anchorManagerChannel = FlutterMethodChannel(name: "aranchors_\(viewId)", binaryMessenger: messenger)
        super.init()

        let configuration = ARWorldTrackingConfiguration() // Create default configuration before initializeARView is called
        self.sceneView.delegate = self
        self.coachingView.delegate = self
        self.sceneView.session.run(configuration)
        self.sceneView.session.delegate = self
        self.sceneView.autoenablesDefaultLighting = true
        self.sceneView.automaticallyUpdatesLighting = true

        self.sessionManagerChannel.setMethodCallHandler(self.onSessionMethodCalled)
        self.objectManagerChannel.setMethodCallHandler(self.onObjectMethodCalled)
        self.anchorManagerChannel.setMethodCallHandler(self.onAnchorMethodCalled)
    }

    func view() -> UIView {
        return self.sceneView
    }

    func onDispose(_ result:FlutterResult) {
                sceneView.session.pause()
                self.sessionManagerChannel.setMethodCallHandler(nil)
                self.objectManagerChannel.setMethodCallHandler(nil)
                self.anchorManagerChannel.setMethodCallHandler(nil)
                result(nil)
            }

    func onSessionMethodCalled(_ call :FlutterMethodCall, _ result:FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>

        switch call.method {
            case "init":
                //self.sessionManagerChannel.invokeMethod("onError", arguments: ["SessionTEST from iOS"])
                //result(nil)
                initializeARView(arguments: arguments!, result: result)
                break
            case "getCameraPose":
                if let cameraPose = sceneView.session.currentFrame?.camera.transform {
                    result(serializeMatrix(cameraPose))
                } else {
                    result(FlutterError())
                }
                break
            case "getAnchorPose":
            if let cameraPose = anchorCollection[arguments?["anchorId"] as! String]?.transform {
                    result(serializeMatrix(cameraPose))
                } else {
                    result(FlutterError())
                }
                break
            case "snapshot":
                // call the SCNView Snapshot method and return the Image
                let snapshotImage = sceneView.snapshot()
                if let bytes = snapshotImage.pngData() {
                    let data = FlutterStandardTypedData(bytes:bytes)
                    result(data)
                } else {
                    result(nil)
                }
            case "dispose":
                onDispose(result)
                result(nil)
                break
            case "showPlanes":
                if let showPlanesArgument = arguments?["showPlanes"] as? Bool {
                        showPlanes = showPlanesArgument
                } else {
                    showPlanes = false
                }
                if (showPlanes){
                    // Visualize currently tracked planes
                    for plane in trackedPlanes.values {
                        plane.0.addChildNode(plane.1)
                    }
                } else {
                    // Remove currently visualized planes
                    for plane in trackedPlanes.values {
                        plane.1.removeFromParentNode()
                    }
                }
                result(nil)
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }

    func onObjectMethodCalled(_ call :FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>
          
        switch call.method {
            case "init":
                DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onError", arguments: ["ObjectTEST from iOS"])}
                result(nil)
                break
            case "addNode":
                addNode(dict_node: arguments!).sink(receiveCompletion: {completion in }, receiveValue: { val in
                       result(val)
                    }).store(in: &self.cancellableCollection)
                break
            case "addNodeToPlaneAnchor":
                if let dict_node = arguments!["node"] as? Dictionary<String, Any>, let dict_anchor = arguments!["anchor"] as? Dictionary<String, Any> {
                    addNode(dict_node: dict_node, dict_anchor: dict_anchor).sink(receiveCompletion: {completion in }, receiveValue: { val in
                           result(val)
                        }).store(in: &self.cancellableCollection)
                }
                break
            case "removeNode":
                if let name = arguments!["name"] as? String {
                    sceneView.scene.rootNode.childNode(withName: name, recursively: true)?.removeFromParentNode()
                }
                break
            case "transformationChanged":
                if let name = arguments!["name"] as? String, let transform = arguments!["transformation"] as? Array<NSNumber> {
                    transformNode(name: name, transform: transform)
                    result(nil)
                }
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }

    func onAnchorMethodCalled(_ call :FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>
          
        switch call.method {
            case "init":
                DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onError", arguments: ["ObjectTEST from iOS"])}
                result(nil)
                break
            case "addAnchor":
                if let type = arguments!["type"] as? Int {
                    switch type {
                    case 0: //Plane Anchor
                        if let transform = arguments!["transformation"] as? Array<NSNumber>, let name = arguments!["name"] as? String {
                            addPlaneAnchor(transform: transform, name: name)
                            result(true)
                        }
                        result(false)
                        break
                    default:
                        result(false)
                    
                    }
                }
                result(nil)
                break
            case "removeAnchor":
                if let name = arguments!["name"] as? String {
                    deleteAnchor(anchorName: name)
                }
                break
            case "initGoogleCloudAnchorMode":
                arcoreSession = try! GARSession.session()

                if (arcoreSession != nil){
                    let configuration = GARSessionConfiguration();
                    configuration.cloudAnchorMode = .enabled;
                    arcoreSession?.setConfiguration(configuration, error: nil);
                    if let token = JWTGenerator().generateWebToken(){
                        arcoreSession!.setAuthToken(token)
                        
                        cloudAnchorHandler = CloudAnchorHandler(session: arcoreSession!)
                        arcoreSession!.delegate = cloudAnchorHandler
                        arcoreSession!.delegateQueue = DispatchQueue.main
                        
                        arcoreMode = true
                    } else {
                        DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Error generating JWT, have you added cloudAnchorKey.json into the ios/Runner directory ?"])}
                    }
                } else {
                    DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Error initializing Google AR Session"])}
                }
                    
                break

       case "uploadAnchor":
    if let anchorName = arguments!["name"] as? String,
       let anchor = anchorCollection[anchorName] {

        // أظهر حلقة الأعمدة فقط الآن بعد ضغط المستخدم uploadAnchor
        self.ringPending = true
        self.hostingAnchorName = anchorName
        self.hostingTriggered = false
        self.qualityRingParent?.removeFromParentNode()
        self.qualityRingParent = nil
        self.qualityStates = Array(repeating: 0, count: self.qualitySegments)

        // تحقق من إطار AR الحالي
        guard let frame = sceneView.session.currentFrame else {
            result(false)
            return
        }

        // يجب أن يكون وضع Google Cloud Anchor مفعّل وتم إنشاء arcoreSession
        guard let arcoreSession = self.arcoreSession else {
            DispatchQueue.main.async {
                self.sessionManagerChannel.invokeMethod("onError", arguments: ["Google Cloud Anchor mode is not initialized"])
            }
            result(false)
            return
        }

        do {
            // 🔍 نفس منطق الكوتلن: استخدم قياس الجودة الرسمي من ARCore iOS
            let quality = try arcoreSession.estimateFeatureMapQualityForHosting(frame.camera.transform)

            switch quality {
            case .good:
                // ✅ فقط عندما تكون الجودة GOOD نستضيف السحابة، مطابق لأندرويد
                if let ttl = arguments?["ttl"] as? Int {
                    cloudAnchorHandler?.hostCloudAnchorWithTtl(
                        anchorName: anchorName,
                        anchor: anchor,
                        listener: cloudAnchorUploadedListener(parent: self),
                        ttl: ttl
                    )
                } else {
                    cloudAnchorHandler?.hostCloudAnchor(
                        anchorName: anchorName,
                        anchor: anchor,
                        listener: cloudAnchorUploadedListener(parent: self)
                    )
                }
                result(true)

            case .sufficient, .insufficient:
                // ❌ نفس رسالة الخطأ في كوتلن عند عدم كفاية البيانات البصرية
                DispatchQueue.main.async {
                    self.sessionManagerChannel.invokeMethod("onError", arguments: ["Insufficient visual data to host cloud anchor"])
                }
                result(false)

            @unknown default:
                DispatchQueue.main.async {
                    self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unknown feature map quality state"])
                }
                result(false)
            }

        } catch {
            // مثلاً NotTracking / IllegalState
            DispatchQueue.main.async {
                self.sessionManagerChannel.invokeMethod("onError", arguments: ["Failed to estimate feature map quality: \(error.localizedDescription)"])
            }
            result(false)
        }

    }
    break


            case "downloadAnchor":
    // نحتاج cloudanchorid من Flutter
    guard let anchorId = arguments?["cloudanchorid"] as? String, !anchorId.isEmpty else {
        DispatchQueue.main.async {
            self.sessionManagerChannel.invokeMethod("onError", arguments: ["cloudanchorid is null or blank"])
        }
        result(false)
        break
    }

    // صفّ التحميل مثل أندرويد + بدء الـ Retry
    enqueueResolve(anchorId)
    result(true)
    break

            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }


    func initializeARView(arguments: Dictionary<String,Any>, result: FlutterResult){
        // Set plane detection configuration
        self.configuration = ARWorldTrackingConfiguration()
        self.configuration.environmentTexturing = .automatic

        // === Read Flutter options ===
        let enabledQualityRing = arguments["enabledQualityRing"] as? Bool
        let segmentsQualityRing = arguments["segmentsQualityRing"] as? Int
        let heightQualityRing = arguments["heightQualityRing"] as? Double
        let radiusQualityRing = arguments["radiusQualityRing"] as? Double
        let columnWidthQualityRing = arguments["columnWidthQualityRing"] as? Double
        let depthOcclusion = arguments["depthOcclusionMode"] as? Bool

        // ✅ Depth Occlusion (Boolean)
        self.depthOcclusionMode = depthOcclusion ?? false
        if self.depthOcclusionMode {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                self.configuration.frameSemantics.insert(.sceneDepth)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                self.configuration.frameSemantics.insert(.personSegmentationWithDepth)
            }
        } else {
            self.configuration.frameSemantics = []
        }

        // ✅ Quality Ring config
        if let en = enabledQualityRing { self.qualityRingEnabled = en }
        if let seg = segmentsQualityRing {
            self.qualitySegments = max(4, min(seg, 72))
            self.qualityStates = Array(repeating: 0, count: self.qualitySegments)
        }
        if let h = heightQualityRing { self.ringHeightMeters = max(Float(h), 0.05) }
        if let r = radiusQualityRing { self.ringRadiusMeters = max(Float(r), 0.08) }
        if let cw = columnWidthQualityRing { self.ringColumnWidth = max(Float(cw), 0.01) }

        // Plane detection
        if let planeDetectionConfig = arguments["planeDetectionConfig"] as? Int {
            switch planeDetectionConfig {
            case 1:
                configuration.planeDetection = .horizontal
            case 2:
                if #available(iOS 11.3, *) {
                    configuration.planeDetection = .vertical
                }
            case 3:
                if #available(iOS 11.3, *) {
                    configuration.planeDetection = [.horizontal, .vertical]
                }
            default:
                configuration.planeDetection = []
            }
        }

        // Set plane rendering options
        if let configShowPlanes = arguments["showPlanes"] as? Bool {
            showPlanes = configShowPlanes
            if (showPlanes){
                for plane in trackedPlanes.values { plane.0.addChildNode(plane.1) }
            } else {
                for plane in trackedPlanes.values { plane.1.removeFromParentNode() }
            }
        }
        if let configCustomPlaneTexturePath = arguments["customPlaneTexturePath"] as? String {
            customPlaneTexturePath = configCustomPlaneTexturePath
        }

        // Debug options
        var debugOptions = ARSCNDebugOptions().rawValue
        if let showFeaturePoints = arguments["showFeaturePoints"] as? Bool, showFeaturePoints {
            debugOptions |= ARSCNDebugOptions.showFeaturePoints.rawValue
        }
        if let showWorldOrigin = arguments["showWorldOrigin"] as? Bool, showWorldOrigin {
            debugOptions |= ARSCNDebugOptions.showWorldOrigin.rawValue
        }
        self.sceneView.debugOptions = ARSCNDebugOptions(rawValue: debugOptions)

        // Gestures
        if let handleTaps = arguments["handleTaps"] as? Bool, handleTaps {
            let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tapGestureRecognizer.delegate = self
    self.sceneView.gestureRecognizers?.append(tapGestureRecognizer)
    }
    if let handlePans = arguments["handlePans"] as? Bool, handlePans {
    let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    panGestureRecognizer.maximumNumberOfTouches = 1
    panGestureRecognizer.delegate = self
    self.sceneView.gestureRecognizers?.append(panGestureRecognizer)
    }
    if let handleRotation = arguments["handleRotation"] as? Bool, handleRotation {
    let rotationGestureRecognizer = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
    rotationGestureRecognizer.delegate = self
    self.sceneView.gestureRecognizers?.append(rotationGestureRecognizer)
    }

    // Coaching view
    if let configShowAnimatedGuide = arguments["showAnimatedGuide"] as? Bool, configShowAnimatedGuide {
    if self.sceneView.superview != nil && self.coachingView.superview == nil {
    self.sceneView.addSubview(self.coachingView)
    self.coachingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    self.coachingView.session = self.sceneView.session
    self.coachingView.activatesAutomatically = true
    self.coachingView.goal = (configuration.planeDetection == .horizontal) ? .horizontalPlane : .verticalPlane
    }
    }

    // Update session configuration
    self.sceneView.session.run(configuration)
    }


    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        
        if let planeAnchor = anchor as? ARPlaneAnchor{
            let plane = modelBuilder.makePlane(anchor: planeAnchor, flutterAssetFile: customPlaneTexturePath)
            trackedPlanes[anchor.identifier] = (node, plane)
            planeCount += 1
            DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onPlaneDetected", arguments: self.planeCount)}
            if (showPlanes) {
                node.addChildNode(plane)
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        
        if let planeAnchor = anchor as? ARPlaneAnchor, let plane = trackedPlanes[anchor.identifier] {
            modelBuilder.updatePlaneNode(planeNode: plane.1, anchor: planeAnchor)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        trackedPlanes.removeValue(forKey: anchor.identifier)
    }
    
func session(_ session: ARSession, didUpdate frame: ARFrame) {
    // أبقِ تحديث GARSession كما هو
    if (arcoreMode) {
        do { try arcoreSession!.update(frame) } catch { print(error) }
    }

    // شغّل منطق الحلقة فقط إذا المستخدم ضغط uploadAnchor
    if arcoreMode, qualityRingEnabled, ringPending,
       let anchorName = hostingAnchorName, let anchor = anchorCollection[anchorName] {

        // ابنِ الحلقة مرة واحدة عند توفر node الأنكور
        if qualityRingParent == nil, let _ = sceneView.node(for: anchor) {
            buildQualityRingAround(anchor: anchor)
        }

        // حدّث عمود القطاع الحالي + نفّذ الرفع التلقائي عند GOOD
        do {
            let q = try arcoreSession!.estimateFeatureMapQualityForHosting(frame.camera.transform)

            if qualityRingParent != nil,
               let camPos = sceneView.session.currentFrame?.camera.transform.columns.3,
               let anchorNode = sceneView.node(for: anchor) {

                let dx = Double(camPos.x - anchorNode.worldPosition.x)
                let dz = Double(camPos.z - anchorNode.worldPosition.z)
                var deg = atan2(dz, dx) * 180.0 / .pi; if deg < 0 { deg += 360.0 }
                let step = 360.0 / Double(qualitySegments)
                var sector = Int(floor(deg / step))
                sector = max(0, min(qualitySegments-1, sector))

                switch q {
                case .good:
                    setColumnState(sector, 2)
                    setColumnState((sector - 1 + qualitySegments) % qualitySegments, 1)
                    setColumnState((sector + 1) % qualitySegments, 1)
                case .sufficient:
                    setColumnState(sector, 1)
                default:
                    break // insufficient
                }
            }

            // ✅ الرفع التلقائي:
            // - أول ما تصير الجودة GOOD نرفع مباشرة (مرة واحدة فقط).
            // - أو إذا اكتملت الحلقة allGood() (احتياطي).
            if !hostingTriggered,
               (q == .good || allGood()),
               let handler = cloudAnchorHandler {

                hostingTriggered = true   // تأكد ما نرفع إلا مرة وحدة
                // ارفع الأنكور (بدون TTL هنا. إن كان عندك TTL مخرّن استخدم hostCloudAnchorWithTtl)
                handler.hostCloudAnchor(
                    anchorName: anchorName,
                    anchor: anchor,
                    listener: cloudAnchorUploadedListener(parent: self)
                )

                // (اختياري) أوقف تحديث الحلقة بعد بدء الرفع
                // ringPending = false
            }

        } catch {
            // تجاهل أخطاء NotTracking/IllegalState حتى تتحسن الحالة
        }
    }
}




    func addNode(dict_node: Dictionary<String, Any>, dict_anchor: Dictionary<String, Any>? = nil) -> Future<Bool, Never> {

        return Future {promise in
            
            switch (dict_node["type"] as! Int) {
                case 0: // GLTF2 Model from Flutter asset folder
                    // Get path to given Flutter asset
                    let key = FlutterDartProject.lookupKey(forAsset: dict_node["uri"] as! String)
                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromGltf(name: dict_node["name"] as! String, modelPath: key, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        promise(.success(true))
                                    } else {
                                        promise(.success(false))
                                    }
                                default:
                                    promise(.success(false))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            promise(.success(true))
                        }
                        promise(.success(false))
                    } else {
                        DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["uri"] as! String)"])}
                        promise(.success(false))
                    }
                    break
//                case 1: // GLB Model from the web
//                    // Add object to scene
//                    self.modelBuilder.makeNodeFromWebGlb(name: dict_node["name"] as! String, modelURL: dict_node["uri"] as! String, transformation: dict_node["transformation"] as? Array<NSNumber>,targetSize: dict_node["targetSize"] as? Float )
//                    .sink(receiveCompletion: {
//                                    completion in print("Async Model Downloading Task completed: ", completion)
//                    }, receiveValue: { val in
//                        if let node: SCNNode = val {
//                            if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
//                                switch anchorType{
//                                    case 0: //PlaneAnchor
//                                        if let anchor = self.anchorCollection[anchorName]{
//                                            // Attach node to the top-level node of the specified anchor
//                                            self.sceneView.node(for: anchor)?.addChildNode(node)
//                                            promise(.success(true))
//                                        } else {
//                                            promise(.success(false))
//                                        }
//                                    default:
//                                        promise(.success(false))
//                                    }
//
//                            } else {
//                                // Attach to top-level node of the scene
//                                self.sceneView.scene.rootNode.addChildNode(node)
//                                promise(.success(true))
//                            }
//                            promise(.success(false))
//                        } else {
//                            DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["name"] as! String)"])}
//                            promise(.success(false))
//                        }
//                    }).store(in: &self.cancellableCollection)
//                    break
                    case 1: // GLB Model from the web (via GlbRenderableLoader)
                    GlbRenderableLoader.shared
                    .load(name: dict_node["name"] as! String,
modelPath: dict_node["uri"] as! String,
transformation: dict_node["transformation"] as? [NSNumber],
targetSize: dict_node["targetSize"] as? Float,
maxRetries: 2)
.sink(receiveCompletion: { _ in
// لا شيء
}, receiveValue: { val in
if let node = val {
if let anchorName = dict_anchor?["name"] as? String,
let anchorType = dict_anchor?["type"] as? Int,
anchorType == 0,
let anchor = self.anchorCollection[anchorName] {
self.sceneView.node(for: anchor)?.addChildNode(node)
promise(.success(true))
} else {
self.sceneView.scene.rootNode.addChildNode(node)
promise(.success(true))
}
promise(.success(false))
} else {
DispatchQueue.main.async {
self.sessionManagerChannel.invokeMethod("onError",
arguments: ["Unable to load renderable \(dict_node["name"] as! String)"])
}
promise(.success(false))
}
}).store(in: &self.cancellableCollection)
break


case 2: // GLB Model from the app's documents folder
                    // Get path to given file system asset
                    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                    let documentsDirectory = paths[0]
                    let targetPath = documentsDirectory.appendingPathComponent(dict_node["uri"] as! String).path
 
                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromFileSystemGLB(name: dict_node["name"] as! String, modelPath: targetPath, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        promise(.success(true))
                                    } else {
                                        promise(.success(false))
                                    }
                                default:
                                    promise(.success(false))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            promise(.success(true))
                        }
                        promise(.success(false))
                    } else {
                        DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["uri"] as! String)"])}
                        promise(.success(false))
                    }
                    break
                case 3: //fileSystemAppFolderGLTF2
                    // Get path to given file system asset
                    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                    let documentsDirectory = paths[0]
                    let targetPath = documentsDirectory.appendingPathComponent(dict_node["uri"] as! String).path

                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromFileSystemGltf(name: dict_node["name"] as! String, modelPath: targetPath, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        promise(.success(true))
                                    } else {
                                        promise(.success(false))
                                    }
                                default:
                                    promise(.success(false))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            promise(.success(true))
                        }
                        promise(.success(false))
                    } else {
                        DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["uri"] as! String)"])}
                        promise(.success(false))
                    }
                    break
                default:
                    promise(.success(false))
            }
            
        }
    }
    
    func transformNode(name: String, transform: Array<NSNumber>) {
        let node = sceneView.scene.rootNode.childNode(withName: name, recursively: true)
        node?.transform = deserializeMatrix4(transform)
    }
    
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }
        let touchLocation = recognizer.location(in: sceneView)
    
        let allHitResults = sceneView.hitTest(touchLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
        // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
        let nodeHitResults: Array<String> = allHitResults.compactMap { nearestParentWithNameStart(node: $0.node, characters: "[#")?.name }
        if (nodeHitResults.count != 0) {
            DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onNodeTap", arguments: Array(Set(nodeHitResults)))} // Chaining of Array and Set is used to remove duplicates
            return
        }
            
        let planeTypes: ARHitTestResult.ResultType
        if #available(iOS 11.3, *){
            planeTypes = ARHitTestResult.ResultType([.existingPlaneUsingGeometry, .featurePoint])
        }else {
            planeTypes = ARHitTestResult.ResultType([.existingPlaneUsingExtent, .featurePoint])
        }
        
        let planeAndPointHitResults = sceneView.hitTest(touchLocation, types: planeTypes)
        
        // store the alignment of the tapped plane anchor so we can refer to is later when transforming the node
        if planeAndPointHitResults.count > 0, let hitAnchor = planeAndPointHitResults.first?.anchor as? ARPlaneAnchor {
            self.tappedPlaneAnchorAlignment = hitAnchor.alignment
        }
            
        let serializedPlaneAndPointHitResults = planeAndPointHitResults.map{serializeHitResult($0)}
        if (serializedPlaneAndPointHitResults.count != 0) {
            DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onPlaneOrPointTap", arguments: serializedPlaneAndPointHitResults)}
        }
    }

    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }

        // State Begins
        if recognizer.state == UIGestureRecognizer.State.began
        {
            panStartLocation = recognizer.location(in: sceneView)
            if let startLocation = panStartLocation {
                let allHitResults = sceneView.hitTest(startLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
                // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
                let nodeHitResults: Array<String> = allHitResults.compactMap {
                    if let nearestNode = nearestParentWithNameStart(node: $0.node, characters: "[#") {
                        panningNode = nearestNode
                        return nearestNode.name
                    }else{
                        return nil
                    }
                }
                if (nodeHitResults.count != 0 && panningNode != nil) {
                    panningNodeCurrentWorldLocation = panningNode!.worldPosition
                    DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onPanStart", arguments: self.panningNode!.name)} // Chaining of Array and Set is used to remove duplicates
                    return
                }
            }
        }
        // State Changes
        if(recognizer.state == UIGestureRecognizer.State.changed)
        {
            // the velocity of the gesture is how fast it is moving. This can be used to translate the position of the node.
            panCurrentVelocity = recognizer.velocity(in: sceneView)
            panCurrentLocation = recognizer.location(in: sceneView)
            panCurrentTranslation = recognizer.translation(in: sceneView)

            if let panLoc = panCurrentLocation, let panNode = panningNode {
                if let query = sceneView.raycastQuery(from: panLoc, allowing: .estimatedPlane, alignment: .any) {
                    guard let result = self.sceneView.session.raycast(query).first else {
                        return
                    }
                    let posX = result.worldTransform.columns.3.x
                    let posY = result.worldTransform.columns.3.y
                    let posZ = result.worldTransform.columns.3.z
                    panNode.worldPosition = SCNVector3(posX, posY, posZ)
                }
                DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onPanChange", arguments: panNode.name)}
            }
        }
        // State Ended
        if(recognizer.state == UIGestureRecognizer.State.ended)
        {
            // kill variables
            panStartLocation = nil
            panCurrentLocation = nil
            DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onPanEnd", arguments: serializeLocalTransformation(node: self.panningNode))}
            panningNode = nil
        }
    }
    
    @objc func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }

        // State Begins
        if recognizer.state == UIGestureRecognizer.State.began
        {
            rotationStartLocation = recognizer.location(in: sceneView)
            if let startLocation = rotationStartLocation {
                let allHitResults = sceneView.hitTest(startLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
                // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
                let nodeHitResults: Array<String> = allHitResults.compactMap {
                    if let nearestNode = nearestParentWithNameStart(node: $0.node, characters: "[#") {
                        panningNode = nearestNode
                        return nearestNode.name
                    }else{
                        return nil
                    }
                }
                if (nodeHitResults.count != 0 && panningNode != nil) {
                    DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onRotationStart", arguments: self.panningNode!.name)} // Chaining of Array and Set is used to remove duplicates
                    return
                }
            }
        }
        // State Changes
        if(recognizer.state == UIGestureRecognizer.State.changed)
        {
            // the velocity of the gesture is how fast it is moving. This can be used to translate the position of the node.
            rotation = recognizer.rotation
            rotationVelocity = recognizer.velocity

            if let r = rotationVelocity, let panNode = panningNode {
                // velocity needs to be reduced substantially otherwise the rotation change seems too fast as radians; also needs inverting to match the movement of the fingers as they rotate on the screen
                let r2 = (r*0.01) * -1
                let nodeRotation = panNode.rotation
                let rotation: SCNQuaternion!
                let planeAlignment = self.tappedPlaneAnchorAlignment
                if planeAlignment == .horizontal {
                    rotation = SCNQuaternion(x: 0, y: 1, z: 0, w: nodeRotation.w+Float(r2)) // quickest way to convert screen into world positions (meters)
                }else{
                    rotation = SCNQuaternion(x: 0, y: 0, z: 1, w: nodeRotation.w+Float(r2)) // quickest way to convert screen into world positions (meters)
                }
                panNode.rotation = rotation
                DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onRotationChange", arguments: panNode.name)}
            }

            // update position of panning node if it has been created
            // panningNode.position + the gesture delta
        }
        // State Ended
        if(recognizer.state == UIGestureRecognizer.State.ended)
        {
            // kill variables
            rotation = nil
            rotationVelocity = nil
            DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onRotationEnd", arguments: serializeLocalTransformation(node: self.panningNode))}
            panningNode = nil
        }
    
    }

    // Recursive helper function to traverse a node's parents until a node with a name starting with the specified characters is found
    func nearestParentWithNameStart(node: SCNNode?, characters: String) -> SCNNode? {
        if let nodeNamePrefix = node?.name?.prefix(characters.count) {
            if (nodeNamePrefix == characters) { return node }
        }
        if let parent = node?.parent { return nearestParentWithNameStart(node: parent, characters: characters) }
        return nil
    }

    func addPlaneAnchor(transform: Array<NSNumber>, name: String){
let arAnchor = ARAnchor(transform: simd_float4x4(deserializeMatrix4(transform)))
anchorCollection[name]= arAnchor sceneView.session.add(anchor: arAnchor)

while (sceneView.node(for: arAnchor) == nil) { usleep(1) }

hostingTriggered = false hostingAnchorName = name qualityRingParent ?.removeFromParentNode()
qualityRingParent = nil qualityStates = Array(repeating: 0, count: qualitySegments)
ringPending = qualityRingEnabled

}

    func deleteAnchor(anchorName: String) {
        if let anchor = anchorCollection[anchorName]{
            // Delete all child nodes
            if var attachedNodes = sceneView.node(for: anchor)?.childNodes {
                attachedNodes.removeAll()
            }
            // Remove anchor
            sceneView.session.remove(anchor: anchor)
            // Update bookkeeping
            anchorCollection.removeValue(forKey: anchorName)
        }
    }
    
    private class cloudAnchorUploadedListener: CloudAnchorListener {
        private var parent: IosARView
        
        init(parent: IosARView) {
            self.parent = parent
        }
        
        func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
            if let cloudState = anchor?.cloudState {
                if (cloudState == GARCloudAnchorState.success) {
                    var args = Dictionary<String, String?>()
                    args["name"] = anchorName
                    args["cloudanchorid"] = anchor?.cloudIdentifier
                    DispatchQueue.main.async {self.parent.anchorManagerChannel.invokeMethod("onCloudAnchorUploaded", arguments: args)}
                } else {
                    print("Error uploading anchor, state: \(parent.decodeCloudAnchorState(state: cloudState))")
                    DispatchQueue.main.async {self.parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error uploading anchor, state: \(self.parent.decodeCloudAnchorState(state: cloudState))"])}
                    return
                }
            }
        }
    }
// Listener: Auto Cloud Anchor Upload
private class autoCloudAnchorUploadedListener: CloudAnchorListener {
    weak var parent: IosARView?

    init(parent: IosARView) {
        self.parent = parent
    }

    func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
        guard let parent = parent else { return }

        if let cloudState = anchor?.cloudState {
            if cloudState != .success {
                // خطأ في الرفع
                DispatchQueue.main.async {
                    parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error uploading anchor, state: \(parent.decodeCloudAnchorState(state: cloudState))"])
                }
                return
            }

            // نجاح: أرسل حدث autoHostCloudAnchor مع الاسم و cloudanchorid
            var args = Dictionary<String, String?>()
            args["name"] = anchorName
            args["cloudanchorid"] = anchor?.cloudIdentifier

            // (على iOS لسنا بحاجة لاستبدال ARAnchor القديم؛ فقط نُعلم Flutter بالـ id)
            DispatchQueue.main.async {
                parent.anchorManagerChannel.invokeMethod("autoHostCloudAnchor", arguments: args)
            }
        } else {
            DispatchQueue.main.async {
                parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error uploading anchor: missing cloud state"])
            }
        }
    }
}

    private class cloudAnchorDownloadedListener: CloudAnchorListener {
        private var parent: IosARView
        
        init(parent: IosARView) {
            self.parent = parent
        }
        
        func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
            if let cloudState = anchor?.cloudState {
                if (cloudState == GARCloudAnchorState.success) {
                    let newAnchor = ARAnchor(transform: anchor!.transform)
                    // Register new anchor on the Flutter side of the plugin
                    DispatchQueue.main.async {self.parent.anchorManagerChannel.invokeMethod("onAnchorDownloadSuccess", arguments: serializeAnchor(anchor: newAnchor, anchorNode: nil, ganchor: anchor!, name: anchorName), result: { result in
                        if let anchorName = result as? String {
                            self.parent.sceneView.session.add(anchor: newAnchor)
                            self.parent.anchorCollection[anchorName] = newAnchor
                        } else {
                            DispatchQueue.main.async {self.parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error while registering downloaded anchor at the AR Flutter plugin"])}
                        }

                    })}
                } else {
                    print("Error downloading anchor, state \(cloudState)")
                    DispatchQueue.main.async {self.parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error downloading anchor, state \(cloudState)"])}
                    return
                }
            }
        }
    }
    
    // MARK: - Auto Host (iOS)
func autoHostCloudAnchor(anchorName: String, ttl: Int = 356) {
    // تأكد تفعيل Cloud Anchor mode
    guard let arcoreSession = self.arcoreSession else {
        DispatchQueue.main.async {
            self.sessionManagerChannel.invokeMethod("onError", arguments: ["Cloud mode not initialized. Call initGoogleCloudAnchorMode first"])
        }
        self.hostingTriggered = false
        return
    }
    // لازم يكون لدينا ARAnchor مسجّل بهذا الاسم
    guard let anchor = self.anchorCollection[anchorName] else {
        DispatchQueue.main.async {
            self.sessionManagerChannel.invokeMethod("onError", arguments: ["Anchor '\(anchorName)' not found"])
        }
        self.hostingTriggered = false
        return
    }
    // تأكد من جودة ممتازة (GOOD) لهذا الفريم
    guard let frame = sceneView.session.currentFrame else {
        DispatchQueue.main.async {
            self.sessionManagerChannel.invokeMethod("onError", arguments: ["AR Frame is null"])
        }
        self.hostingTriggered = false
        return
    }

    do {
        let quality = try arcoreSession.estimateFeatureMapQualityForHosting(frame.camera.transform)
        guard quality == .good else {
            // احتياط: لا ترفع لو الجودة ليست GOOD الآن
            self.hostingTriggered = false
            return
        }
    } catch {
        self.hostingTriggered = false
        DispatchQueue.main.async {
            self.sessionManagerChannel.invokeMethod("onError", arguments: ["Auto host failed: \(error.localizedDescription)"])
        }
        return
    }

    // ارفع باستخدام Listener خاص بالـ auto-host (يرسل autoHostCloudAnchor)
    if let handler = self.cloudAnchorHandler {
        handler.hostCloudAnchorWithTtl(
            anchorName: anchorName,
            anchor: anchor,
            listener: autoCloudAnchorUploadedListener(parent: self),
            ttl: ttl
        )
        // سيصل إشعار النجاح عبر listener أدناه
    } else {
        self.hostingTriggered = false
        DispatchQueue.main.async {
            self.sessionManagerChannel.invokeMethod("onError", arguments: ["Cloud mode not initialized. Call initGoogleCloudAnchorMode first"])
        }
    }
}

    func decodeCloudAnchorState(state: GARCloudAnchorState) -> String {
        switch state {
        case .errorCloudIdNotFound:
            return "Cloud anchor id not found"
        case .errorHostingDatasetProcessingFailed:
            return "Dataset processing failed, feature map insufficient"
        case .errorHostingServiceUnavailable:
            return "Hosting service unavailable"
        case .errorInternal:
            return "Internal error"
        case .errorNotAuthorized:
            return "Authentication failed: Not Authorized"
        case .errorResolvingSdkVersionTooNew:
            return "Resolving Sdk version too new"
        case .errorResolvingSdkVersionTooOld:
            return "Resolving Sdk version too old"
        case .errorResourceExhausted:
            return " Resource exhausted"
        case .none:
            return "Empty state"
        case .taskInProgress:
            return "Task in progress"
        case .success:
            return "Success"
        case .errorServiceUnavailable:
            return "Cloud Anchor Service unavailable"
        case .errorResolvingLocalizationNoMatch:
            return "No match"
        @unknown default:
            return "Unknown"
        }
    }
func showToast(message: String, duration: Double = 2.0) {
    let toastLabel = UILabel(frame: CGRect(x: 20,
                                           y: sceneView.frame.size.height - 150,
                                           width: sceneView.frame.size.width - 40,
                                           height: 35))
    toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    toastLabel.textColor = UIColor.white
    toastLabel.textAlignment = .center
    toastLabel.font = UIFont.systemFont(ofSize: 16)
    toastLabel.text = message
    toastLabel.alpha = 0.0
    toastLabel.layer.cornerRadius = 10
    toastLabel.clipsToBounds = true

    sceneView.addSubview(toastLabel)

    UIView.animate(withDuration: 0.5, animations: {
        toastLabel.alpha = 1.0
    }) { _ in
        UIView.animate(withDuration: 0.5, delay: duration, options: .curveEaseOut, animations: {
            toastLabel.alpha = 0.0
        }) { _ in
            toastLabel.removeFromSuperview()
        }
    }
}
  
  private func buildQualityRingAround(anchor: ARAnchor) {
    guard let anchorNode = self.sceneView.node(for: anchor) else { return }

    // أزل القديم
    qualityRingParent?.removeFromParentNode()
    let parent = SCNNode()
    parent.name = "quality_ring_parent"
    anchorNode.addChildNode(parent)
    qualityRingParent = parent

    // أعد ضبط الحالات
    for i in 0..<qualityStates.count { qualityStates[i] = 0 }

    let stepDeg = 360.0 / Double(qualitySegments)
    for i in 0..<qualitySegments {
        let angleRad = (Double(i) * stepDeg) * .pi / 180.0
        let x = CGFloat(ringRadiusMeters * Float(cos(angleRad)))
        let z = CGFloat(ringRadiusMeters * Float(sin(angleRad)))

        let cyl = SCNCylinder(radius: CGFloat(ringColumnWidth/2.0), height: CGFloat(ringHeightMeters))
        cyl.firstMaterial = matRed

        let node = SCNNode(geometry: cyl)
        node.position = SCNVector3(x, CGFloat(ringHeightMeters/2.0), z)

        // توجيه العمود نحو المركز
        node.look(at: SCNVector3(0, node.position.y, 0))
        node.name = "quality_col_\(i)"
        parent.addChildNode(node)
    }
}

private func setColumnState(_ index: Int, _ state: Int) {
    guard index >= 0 && index < qualityStates.count else { return }
    if state <= qualityStates[index] { return } // لا ننزل الحالة
    qualityStates[index] = state

    if let cols = qualityRingParent?.childNodes, index < cols.count,
       let geo = cols[index].geometry {
        switch state {
        case 2: geo.firstMaterial = matGreen
        case 1: geo.firstMaterial = matYellow
        default: geo.firstMaterial = matRed
        }
    }
}

private func allGood() -> Bool {
    let total = qualityStates.count
    guard total > 0 else { return false }
    let c2 = qualityStates.filter { $0 == 2 }.count
    let c1 = qualityStates.filter { $0 == 1 }.count
    let only1or2 = (c1 + c2 == total)          // كل الأعمدة شوهدت
    if !only1or2 { return false }
    // >=50% أو >=70% أخضر (مطابق لمنطق أندرويد الشائع)
    return (c2 * 2 >= total) || (c2 * 10 >= 7 * total)
}

// MARK: - Resolve Queue

private func enqueueResolve(_ id: String) {
    resolveQueue.append(id)
    if !resolving { processNextResolve() }
}

private func processNextResolve() {
    guard !resolveQueue.isEmpty else {
        resolving = false
        pendingResolveId = nil
        currentResolveRetryCount = 0
        return
    }

    let next = resolveQueue.removeFirst()
    resolving = true
    pendingResolveId = next
    currentResolveRetryCount = 0

    // ابدأ حلّ المعرف هذا مع إعادة المحاولة
    resolveCloudAnchorWithRetry(
        anchorId: next,
        attempt: 0,
        maxRetries: maxResolveRetriesDefault,
        baseDelayMs: baseResolveDelayMsDefault
    )

    // لتسلسل بسيط مشابه للأندرويد، تابع العنصر التالي بعد مهلة قصيرة
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.processNextResolve()
    }
}

// MARK: - Resolve with Retry

func resolveCloudAnchorWithRetry(
    anchorId: String,
    attempt: Int = 0,
    maxRetries: Int = 5,
    baseDelayMs: Int = 750
) {
    // أبلِغ Flutter بالمحاولة
    DispatchQueue.main.async {
        self.sessionManagerChannel.invokeMethod("onCloudAnchorResolveAttempt",
                                                arguments: [anchorId, attempt, maxRetries])
    }

    // تأكد أن وضع Google Cloud Anchor مفعّل
    guard self.arcoreSession != nil, self.cloudAnchorHandler != nil else {
        DispatchQueue.main.async {
            self.sessionManagerChannel.invokeMethod("onError",
                                                    arguments: ["Google Cloud Anchor mode is not initialized"])
        }
        return
    }

    // نفّذ الـ resolve مع Listener يدعم إعادة المحاولة
    self.cloudAnchorHandler?.resolveCloudAnchor(
        anchorId: anchorId,
        listener: CloudAnchorResolveRetryListener(
            parent: self,
            anchorId: anchorId,
            attempt: attempt,
            maxRetries: maxRetries,
            baseDelayMs: baseDelayMs
        )
    )
}

// أي الحالات نعيد المحاولة لها (مماثلة لفكرة shouldRetry في أندرويد)
func shouldRetry(_ state: GARCloudAnchorState) -> Bool {
    switch state {
    case .taskInProgress,
         .errorServiceUnavailable,
         .errorHostingServiceUnavailable,
         .errorResourceExhausted,
         .errorInternal,
         .errorResolvingLocalizationNoMatch:
        return true
    default:
        return false
    }
}

// Listener داخلي لإدارة النجاح/الفشل والـ Retry الأُسّي
private class CloudAnchorResolveRetryListener: CloudAnchorListener {
    weak var parent: IosARView?
    let anchorId: String
    let attempt: Int
    let maxRetries: Int
    let baseDelayMs: Int

    init(parent: IosARView,
         anchorId: String,
         attempt: Int,
         maxRetries: Int,
         baseDelayMs: Int) {
        self.parent = parent
        self.anchorId = anchorId
        self.attempt = attempt
        self.maxRetries = maxRetries
        self.baseDelayMs = baseDelayMs
    }

    func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
        guard let parent = parent else { return }

        // Anchor = nil -> Retry حتى maxRetries
        guard let ganchor = anchor else {
            if attempt < maxRetries {
                let nextDelay = Double(baseDelayMs * (1 << attempt)) / 1000.0
                DispatchQueue.main.asyncAfter(deadline: .now() + nextDelay) {
                    parent.resolveCloudAnchorWithRetry(
                        anchorId: self.anchorId,
                        attempt: self.attempt + 1,
                        maxRetries: self.maxRetries,
                        baseDelayMs: self.baseDelayMs
                    )
                }
            } else {
                let msg = "Error downloading anchor: null anchor after \(maxRetries) attempts"
                DispatchQueue.main.async {
                    parent.sessionManagerChannel.invokeMethod("onError", arguments: [msg])
                }
            }
            return
        }

        let state = ganchor.cloudState
        switch state {
        case .success:
            // ✅ نفس منطق التسجيل الموجود لديك في listener الأصلي
            let newAnchor = ARAnchor(transform: ganchor.transform)
            DispatchQueue.main.async {
                parent.anchorManagerChannel.invokeMethod(
                    "onAnchorDownloadSuccess",
                    arguments: serializeAnchor(anchor: newAnchor, anchorNode: nil, ganchor: ganchor, name: anchorName),
                    result: { result in
                        if let anchorName = result as? String {
                            parent.sceneView.session.add(anchor: newAnchor)
                            parent.anchorCollection[anchorName] = newAnchor
                        } else {
                            parent.sessionManagerChannel.invokeMethod(
                                "onError",
                                arguments: ["Error while registering downloaded anchor at the AR Flutter plugin"]
                            )
                        }
                    }
                )
            }

        default:
            // خطأ — قرر إعادة المحاولة أو الفشل النهائي
            if parent.shouldRetry(state), attempt < maxRetries {
                let nextDelay = Double(baseDelayMs * (1 << attempt)) / 1000.0
                DispatchQueue.main.asyncAfter(deadline: .now() + nextDelay) {
                    parent.resolveCloudAnchorWithRetry(
                        anchorId: self.anchorId,
                        attempt: self.attempt + 1,
                        maxRetries: self.maxRetries,
                        baseDelayMs: self.baseDelayMs
                    )
                }
            } else {
                let msg = "Error downloading anchor, state \(state) (attempts=\(attempt))"
                DispatchQueue.main.async {
                    parent.sessionManagerChannel.invokeMethod("onError", arguments: [msg])
                }
            }
        }
    }
}

}

// ---------------------- ARCoachingOverlayViewDelegate ---------------------------------------

extension IosARView: ARCoachingOverlayViewDelegate {
    
    func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView){
        // use this delegate method to hide anything in the UI that could cover the coaching overlay view
    }
    
    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        // Reset the session.
        self.sceneView.session.run(configuration, options: [.resetTracking])
    }


}
