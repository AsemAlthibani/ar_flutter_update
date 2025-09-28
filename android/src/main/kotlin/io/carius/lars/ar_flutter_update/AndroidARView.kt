package io.carius.lars.ar_flutter_update

import android.R
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.view.doOnPreDraw
import com.google.ar.core.*
import com.google.ar.core.exceptions.*
import com.google.ar.sceneform.*
import com.google.ar.sceneform.animation.ModelAnimator
import com.google.ar.sceneform.collision.Box
import com.google.ar.sceneform.math.Vector3
import com.google.ar.sceneform.rendering.*
import com.google.ar.sceneform.ux.*
import io.carius.lars.ar_flutter_update.Serialization.deserializeMatrix4s
import io.carius.lars.ar_flutter_update.Serialization.serializeAnchor
import io.carius.lars.ar_flutter_update.Serialization.serializeHitResult
import io.carius.lars.ar_flutter_update.Serialization.serializePoses
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.FloatBuffer
import java.util.concurrent.CompletableFuture
import kotlin.math.min

internal class AndroidARView(
    val activity: Activity,
    context: Context,
    messenger: BinaryMessenger,
    id: Int,
    creationParams: Map<String?, Any?>?
) : PlatformView {
    // constants
    private val TAG: String = AndroidARView::class.java.name

    private fun hasCameraPermission(): Boolean {
        return ContextCompat.checkSelfPermission(activity, android.Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    }

    // Lifecycle variables
    private var mUserRequestedInstall = true
    lateinit var activityLifecycleCallbacks: Application.ActivityLifecycleCallbacks
    private val viewContext: Context
    private var isDisposed = false

    // Platform channels
    private val sessionManagerChannel: MethodChannel = MethodChannel(messenger, "arsession_$id")
    private val objectManagerChannel: MethodChannel = MethodChannel(messenger, "arobjects_$id")
    private val anchorManagerChannel: MethodChannel = MethodChannel(messenger, "aranchors_$id")

    // UI variables
    private lateinit var arSceneView: ArSceneView
    private lateinit var transformationSystem: TransformationSystem
    private var showFeaturePoints = false
    private var showAnimatedGuide = false
    private lateinit var animatedGuide: View
    private lateinit var animatedGuide2: View
    private var pointCloudNode = Node()
    private var worldOriginNode = Node()

    // Setting defaults
    private var enableRotation = false
    private var enablePans = false
    private var keepNodeSelected = true
    private var footprintSelectionVisualizer = FootprintSelectionVisualizer()

    // Model builder
    private var modelBuilder = ArModelBuilders()

    // Cloud anchor handler
    private lateinit var cloudAnchorHandler: CloudAnchorHandlers
    private lateinit var andyRenderable: ModelRenderable
    private lateinit var hatRenderable: ModelRenderable
    private lateinit var animator: ModelAnimator
    private var nextAnimation = 0

    private lateinit var sceneUpdateListener: com.google.ar.sceneform.Scene.OnUpdateListener
    private lateinit var onNodeTapListener: com.google.ar.sceneform.Scene.OnPeekTouchListener
    private var detectedPlanes = HashSet<Plane>()
    private var planeCount = 0
    private var isCameraEnabled = true
    private var sunNode: Node? = null
    private var qualityRingParent: Node? = null
    private var qualitySegments: Int = 16                     // عدد الأعمدة حول العنصر
    private var qualityStates: IntArray = IntArray(qualitySegments) { 0 }// 0=UNSEEN, 1=SEEN_OK (>= SUFFICIENT), 2=GOOD

    private var hostingTriggered = false
    private var hostingAnchorName: String? = null        // اسم الـ Anchor المراد رفعه تلقائياً
    private var ringRadiusMeters = 0.6f
    private var ringHeightMeters = 0.25f
    private var ringColumnWidth = 0.05f

    private lateinit var matRed: Material
    private lateinit var matYellow: Material
    private lateinit var matGreen: Material
    private var matsReady = false
    private var ringPending = false // نية إظهار الحلقة بعد ظهور العنصر
    private var qualityRingEnabled = true                 // تشغيل/إيقاف الحلقة
    private var depthOcclusionMode = false
    private val resolveQueue = ArrayDeque<String>()
    private var resolving = false



    // Method channel handlers
    private val onSessionMethodCall =
        object : MethodChannel.MethodCallHandler {
            override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
                Log.d(TAG, "AndroidARView onsessionmethodcall reveived a call!")
                when (call.method) {
                    "init" -> {
                        initializeARView(call, result)
                    }
                    "getAnchorPose" -> {
                        val anchorNode = arSceneView.scene.findByName(call.argument("anchorId")) as AnchorNode?
                        if (anchorNode != null) {
                            result.success(serializePoses(anchorNode.anchor!!.pose))
                        } else {
                            result.error("Error", "could not get anchor pose", null)
                        }
                    }
                    "getCameraPose" -> {
                        val cameraPose = arSceneView.arFrame?.camera?.displayOrientedPose
                        if (cameraPose != null) {
                            result.success(serializePoses(cameraPose))
                        } else {
                            result.error("Error", "could not get camera pose", null)
                        }
                    }
                    "snapshot" -> {
                        // حماية قبل الالتقاط
                        if (arSceneView.width <= 0 || arSceneView.height <= 0) {
                            result.error("e", "AR view not ready for snapshot", null)
                            return
                        }

                        val bitmap = Bitmap.createBitmap(
                            arSceneView.width, arSceneView.height,
                            Bitmap.Config.ARGB_8888
                        )

                        // Create a handler thread to offload the processing of the image.
                        val handlerThread = HandlerThread("PixelCopier")
                        handlerThread.start()
                        // Make the request to copy.
                        PixelCopy.request(arSceneView, bitmap, { copyResult: Int ->
                            Log.d(TAG, "PIXELCOPY DONE")
                            if (copyResult == PixelCopy.SUCCESS) {
                                try {
                                    val mainHandler = Handler(context.mainLooper)
                                    val runnable = Runnable {
                                        val stream = ByteArrayOutputStream()
                                        bitmap.compress(Bitmap.CompressFormat.PNG, 90, stream)
                                        val data = stream.toByteArray()
                                        result.success(data)
                                    }
                                    mainHandler.post(runnable)
                                } catch (e: IOException) {
                                    result.error("e", e.message, e.stackTrace)
                                }
                            } else {
                                result.error("e", "failed to take screenshot", null)
                            }
                            handlerThread.quitSafely()
                        }, Handler(handlerThread.looper))
                    }
                    "dispose" -> {
                        dispose()
                    }
                    "disableCamera" -> {
                        arSceneView.visibility = View.GONE
                        arSceneView.scene?.removeOnPeekTouchListener(onNodeTapListener)
                        isCameraEnabled = false
                    }
                    "enableCamera" -> {
                        arSceneView.visibility = View.VISIBLE
                        arSceneView.scene?.addOnPeekTouchListener(onNodeTapListener)
                        isCameraEnabled = true
                    }
                    "showPlanes" -> {
                        arSceneView.planeRenderer.isVisible = call.argument<Boolean>("showPlanes") ?: false
                    }
                    else -> {}
                }
            }
        }

    private val onObjectMethodCall =
        object : MethodChannel.MethodCallHandler {
            override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
                Log.d(TAG, "AndroidARView onobjectmethodcall reveived a call!")
                when (call.method) {
                    "init" -> { /* no-op */ }
                    "addNode" -> {
                        val dict_node: HashMap<String, Any>? = call.arguments as? HashMap<String, Any>
                        dict_node?.let {
                            addNode(it).thenAccept { status: Boolean ->
                                result.success(status)
                            }.exceptionally { throwable ->
                                result.error("e", throwable.message, throwable.stackTrace)
                                null
                            }
                        }
                    }
                    "addNodeToPlaneAnchor" -> {
                        val dict_node: HashMap<String, Any>? = call.argument("node")
                        val dict_anchor: HashMap<String, Any>? = call.argument("anchor")
                        val showDailog: Boolean? = call.argument("showDailog")
                        if (dict_node != null && dict_anchor != null) {
                            addNode(dict_node, dict_anchor).thenAccept { status: Boolean ->
                                if (status) {
                                    if (showDailog == true) {
                                        val view = activity.findViewById(R.id.content) as ViewGroup
                                        if (!::animatedGuide2.isInitialized || animatedGuide2.parent == null) {
                                            animatedGuide2 = activity.layoutInflater.inflate(
                                                io.carius.lars.ar_flutter_update.R.layout.my_sceneform_plane_layout,
                                                null
                                            )
                                            view.addView(animatedGuide2)
                                        }
                                    }
                                }
                                result.success(status)
                            }.exceptionally { throwable ->
                                result.error("e", throwable.message, throwable.stackTrace)
                                null
                            }
                        } else {
                            result.success(false)
                        }
                    }
                    "removeNode" -> {
                        val nodeName: String? = call.argument("name")
                        nodeName?.let {
                            if (transformationSystem.selectedNode?.name == nodeName) {
                                transformationSystem.selectNode(null)
                                keepNodeSelected = true
                            }
                            val node = arSceneView.scene.findByName(nodeName)
                            node?.let { n ->
                                arSceneView.scene.removeChild(n)
                                result.success(null)
                            }
                        }
                    }
                    "transformationChanged" -> {
                        val nodeName: String? = call.argument("name")
                        val newTransformation: ArrayList<Double>? = call.argument("transformation")
                        nodeName?.let { name ->
                            newTransformation?.let { transform ->
                                transformNode(name, transform)
                                result.success(null)
                            }
                        }
                    }
                    else -> {}
                }
            }
        }

    private val onAnchorMethodCall =
        object : MethodChannel.MethodCallHandler {
            override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
                when (call.method) {
                    "addAnchor" -> {
                        val anchorType: Int? = call.argument("type")
                        if (anchorType != null) {
                            when (anchorType) {
                                0 -> { // Plane Anchor
                                    val transform: ArrayList<Double>? = call.argument("transformation")
                                    val name: String? = call.argument("name")
                                    if (name != null && transform != null) {
                                        result.success(addPlaneAnchor(transform, name))
                                    } else {
                                        result.success(false)
                                    }
                                }
                                else -> result.success(false)
                            }
                        } else {
                            result.success(false)
                        }
                    }
                    "removeAnchor" -> {
                        val anchorName: String? = call.argument("name")
                        anchorName?.let { name ->
                            removeAnchor(name)
                        }
                    }
                    "initGoogleCloudAnchorMode" -> {
                        if (arSceneView.session != null) {
                            val config = Config(arSceneView.session)
                            config.cloudAnchorMode = Config.CloudAnchorMode.ENABLED
                            config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                            config.focusMode = Config.FocusMode.AUTO
                            try {
                                config.lightEstimationMode = Config.LightEstimationMode.ENVIRONMENTAL_HDR
                            } catch (e: NoClassDefFoundError) {
                                config.setLightEstimationMode(Config.LightEstimationMode.ENVIRONMENTAL_HDR) // Deprecated
                            }
                            if (arSceneView.session!!.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                                config.depthMode = Config.DepthMode.AUTOMATIC
                            }
                            arSceneView.session?.configure(config)
                            ensureSunLight(120_000f)



                            cloudAnchorHandler = CloudAnchorHandlers(arSceneView.session!!)
                        } else {
                            sessionManagerChannel.invokeMethod("onError", listOf("Error initializing cloud anchor mode: Session is null"))
                        }
                    }
                    "uploadAnchor" -> {
                        val anchorName: String? = call.argument("name")
                        val ttl: Int = call.argument<Int>("ttl") ?: 365
                        val frame = arSceneView.arFrame
                        ringPending = true
                        hostingAnchorName = anchorName
                        if (frame != null) {
                            val pointCloud = frame.acquirePointCloud()
                            pointCloud.release()
                            val quality = arSceneView.session?.estimateFeatureMapQualityForHosting(frame.camera.pose)
                            if (quality == Session.FeatureMapQuality.INSUFFICIENT || quality == Session.FeatureMapQuality.SUFFICIENT) {
                                sessionManagerChannel.invokeMethod("onError", listOf("Insufficient visual data to host cloud anchor"))
                                result.success(false)
                                return
                            }
                            if (quality == Session.FeatureMapQuality.GOOD) {
                                anchorName?.let {
                                    val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
                                    if (anchorNode?.anchor == null) {
                                        result.success(false)
                                        return
                                    }
                                    if (ttl != null) {
                                        cloudAnchorHandler.hostCloudAnchorWithTtl(
                                            anchorName,
                                            anchorNode.anchor,
                                            cloudAnchorUploadedListener(),
                                            ttl
                                        )
                                    } else {
                                        cloudAnchorHandler.hostCloudAnchor(
                                            anchorName,
                                            anchorNode.anchor,
                                            cloudAnchorUploadedListener()
                                        )
                                    }
                                    result.success(true)
                                }
                            } else {
                                result.success(false)
                            }
                        } else {
                            result.error("error", "AR Frame is null", null)
                        }
                    }
                    "downloadAnchor" -> {
                        val anchorId: String? = call.argument<String>("cloudanchorid")
                        if (anchorId.isNullOrBlank()) {
                            sessionManagerChannel.invokeMethod("onError", listOf("cloudanchorid is null or blank"))
                            return
                        }
                        enqueueResolve(anchorId)
                    }
                    else -> {}
                }
            }
        }

    override fun getView(): View = arSceneView

    override fun dispose() {
        isDisposed = true
        activity.application.unregisterActivityLifecycleCallbacks(activityLifecycleCallbacks)

        try { onPause() } catch (_: Exception) {}
        val rootView = activity.findViewById<ViewGroup>(android.R.id.content)
        try { removeGuide(animatedGuide) } catch (_: Exception) {}
        try { rootView.removeView(animatedGuide2) } catch (_: Exception) {}
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        try {
            arSceneView.session?.close()
            arSceneView.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "dispose destroy issue: ${e.message}")
        }
    }



    init {
        Log.d(TAG, "Initializing AndroidARView")
        viewContext = context

        arSceneView = ArSceneView(context)
        setupLifeCycle(context)

        sessionManagerChannel.setMethodCallHandler(onSessionMethodCall)
        objectManagerChannel.setMethodCallHandler(onObjectMethodCall)
        anchorManagerChannel.setMethodCallHandler(onAnchorMethodCall)

        MaterialFactory.makeTransparentWithColor(context, Color(255f, 255f, 255f, 0.3f))
            .thenAccept { mat ->
                footprintSelectionVisualizer.footprintRenderable =
                    ShapeFactory.makeCylinder(0.7f, 0.05f, Vector3(0f, 0f, 0f), mat)
            }

        transformationSystem = TransformationSystem(
            activity.resources.displayMetrics,
            footprintSelectionVisualizer
        )

        onResume() // call onResume once to setup initial session
        MaterialFactory.makeOpaqueWithColor(viewContext, Color(1f, 0f, 0f))     // أحمر
            .thenCompose { mr ->
                matRed = mr
                MaterialFactory.makeOpaqueWithColor(viewContext, Color(1f, 1f, 0f))  // أصفر
            }.thenCompose { my ->
                matYellow = my
                MaterialFactory.makeOpaqueWithColor(viewContext, Color(0f, 1f, 0f))  // أخضر
            }.thenAccept { mg ->
                matGreen = mg
                matsReady = true
            }

    }

    private fun setupLifeCycle(context: Context) {
        activityLifecycleCallbacks =
            object : Application.ActivityLifecycleCallbacks {
                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
                    Log.d(TAG, "onActivityCreated")
                }

                override fun onActivityStarted(activity: Activity) {
                    Log.d(TAG, "onActivityStarted")
                }

                override fun onActivityResumed(activity: Activity) {
                    Log.d(TAG, "onActivityResumed")
                    if (!isDisposed) onResume()
                }

                override fun onActivityPaused(activity: Activity) {
                    Log.d(TAG, "onActivityPaused")
                    if (!isDisposed) onPause()
                }

                override fun onActivityStopped(activity: Activity) {
                    Log.d(TAG, "onActivityStopped")
                    if (!isDisposed) onPause()
                }

                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

                override fun onActivityDestroyed(activity: Activity) {
                    Log.d(TAG, "onActivityDestroyed")
                    // لا تنادِ onDestroy هنا؛ صار يُدار من dispose()
                }
            }

        activity.application.registerActivityLifecycleCallbacks(this.activityLifecycleCallbacks)
    }

    fun onResume() {
        if (isDisposed) {
            Log.w(TAG, "onResume called after dispose; ignoring")
            return
        }

        // تحقق من إذن الكاميرا قبل أي شيء
        if (!hasCameraPermission()) {
            Toast.makeText(activity, "يتطلب الواقع المعزز إذن الكاميرا. امنح الإذن من الإعدادات ثم أعد المحاولة.", Toast.LENGTH_LONG).show()
            Log.w(TAG, "Camera permission not granted; skipping AR resume")
            return
        }

        // إن لم توجد جلسة، أنشئ واحدة
        if (arSceneView.session == null) {
            Log.d(TAG, "ARSceneView session is null. Trying to initialize")
            try {
                val session: Session? =
                    if (ArCoreApk.getInstance().requestInstall(activity, mUserRequestedInstall) ==
                        ArCoreApk.InstallStatus.INSTALL_REQUESTED
                    ) {
                        Log.d(TAG, "Install of ArCore APK requested")
                        mUserRequestedInstall = false
                        null
                    } else {
                        Session(activity)
                    }

                if (session == null) {
                    Log.w(TAG, "ARCore session is null. Returning.")
                    return
                }

                val config = Config(session)
                config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                config.focusMode = Config.FocusMode.AUTO
                try {
                    config.lightEstimationMode = Config.LightEstimationMode.ENVIRONMENTAL_HDR
                } catch (e: NoClassDefFoundError) {
                    config.setLightEstimationMode(Config.LightEstimationMode.ENVIRONMENTAL_HDR)
                }

                if (session.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                    config.depthMode = Config.DepthMode.AUTOMATIC
                }
                session.configure(config)

                arSceneView.session = session
                Log.d(TAG, "ARCore session assigned to arSceneView successfully.")

                ensureSunLight(120_000f)

                // عمق

            } catch (ex: UnavailableUserDeclinedInstallationException) {
                Toast.makeText(activity, "User declined ARCore install: ${ex.localizedMessage}", Toast.LENGTH_LONG).show()
                return
            } catch (ex: UnavailableArcoreNotInstalledException) {
                Toast.makeText(activity, "Please install ARCore", Toast.LENGTH_LONG).show()
                return
            } catch (ex: UnavailableApkTooOldException) {
                Toast.makeText(activity, "Please update ARCore", Toast.LENGTH_LONG).show()
                return
            } catch (ex: UnavailableSdkTooOldException) {
                Toast.makeText(activity, "Please update this app", Toast.LENGTH_LONG).show()
                return
            } catch (ex: UnavailableDeviceNotCompatibleException) {
                Toast.makeText(activity, "This device does not support AR", Toast.LENGTH_LONG).show()
                return
            } catch (e: Exception) {
                Log.e(TAG, "Failed to create AR session", e)
                Toast.makeText(activity, "Failed to create AR session: ${e.message}", Toast.LENGTH_LONG).show()
                return
            }
        }

        try {
            activity.runOnUiThread {
                try {
                    arSceneView.resume()
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } catch (ex: CameraNotAvailableException) {
                    Log.e(TAG, "Unable to get camera", ex)
                    Toast.makeText(
                        activity,
                        "الكاميرا غير متاحة حالياً. تأكد أنها ليست مستخدمة بتطبيق آخر ثم حاول مجدداً.",
                        Toast.LENGTH_LONG
                    ).show()
                } catch (e: Exception) {
                    Log.e(TAG, "arSceneView.resume() threw an exception", e)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "runOnUiThread failed", e)
        }

    }

    fun onPause() {
        if (isDisposed) return

        // hide instructions view if no longer required
        val rootView = activity.findViewById<ViewGroup>(android.R.id.content)
        try { removeGuide(animatedGuide) } catch (_: Exception) {}
        try { rootView.removeView(animatedGuide2) } catch (_: Exception) {}
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (showAnimatedGuide) {
            showAnimatedGuide = false
        }
        try {
            arSceneView.pause()
        } catch (e: Exception) {
            Log.w(TAG, "arSceneView.pause() failed: ${e.message}")
        }
    }

    fun onDestroy() {
        try {
            arSceneView.scene?.removeOnUpdateListener(sceneUpdateListener)
            arSceneView.scene?.removeOnPeekTouchListener(onNodeTapListener)

            sunNode?.setParent(null)
            sunNode = null
            // ⚠️ لا تغلق الجلسة هنا
            // ولا تستدعِ destroy() إلا من dispose()
        } catch (e: Exception) {
            Log.w(TAG, "onDestroy issue: ${e.message}")
        }
    }

    private fun initializeARView(call: MethodCall, result: MethodChannel.Result) {
        // Unpack call arguments
        val argShowFeaturePoints: Boolean? = call.argument("showFeaturePoints")
        val argPlaneDetectionConfig: Int? = call.argument("planeDetectionConfig")
        val argShowPlanes: Boolean? = call.argument("showPlanes")
        val argCustomPlaneTexturePath: String? = call.argument("customPlaneTexturePath")
        val argShowWorldOrigin: Boolean? = call.argument("showWorldOrigin")
        val argHandleTaps: Boolean? = call.argument("handleTaps")
        val argHandleRotation: Boolean? = call.argument("handleRotation")
        val argHandlePans: Boolean? = call.argument("handlePans")
        val argShowAnimatedGuide: Boolean? = call.argument("showAnimatedGuide")
        val arEnabledQualityRing: Boolean? = call.argument("enabledQualityRing")
        val arDepthOcclusionMode: Boolean? = call.argument("depthOcclusionMode")
        val arSegmentsQualityRing: Int? = call.argument<Int>("segmentsQualityRing")
        val arHeightQualityRing: Double? = call.argument<Double>("heightQualityRing")      // من Dart توصل double
        val arRadiusQualityRing: Double? = call.argument<Double>("radiusQualityRing")
        val arColumnWidthQualityRing: Double? = call.argument<Double>("columnWidthQualityRing")
        sceneUpdateListener = com.google.ar.sceneform.Scene.OnUpdateListener { frameTime: FrameTime ->
            onFrame(frameTime)
        }
        onNodeTapListener =
            com.google.ar.sceneform.Scene.OnPeekTouchListener { hitTestResult, motionEvent ->
                if (hitTestResult.node != null && motionEvent?.action == MotionEvent.ACTION_DOWN) {
                    objectManagerChannel.invokeMethod("onNodeTap", listOf(hitTestResult.node?.name))
                }
                transformationSystem.onTouch(hitTestResult, motionEvent)
            }

        arSceneView.scene?.addOnUpdateListener(sceneUpdateListener)
        arSceneView.scene?.addOnPeekTouchListener(onNodeTapListener)

        // Configure Plane scanning guide
        if (argShowAnimatedGuide == true) {
            showAnimatedGuide = true
            val view = activity.findViewById(R.id.content) as ViewGroup
            animatedGuide = activity.layoutInflater.inflate(
                io.carius.lars.ar_flutter_update.R.layout.sceneform_hand_layout,
                null
            )
            view.addView(animatedGuide)
            val hand =
                animatedGuide.findViewById<View>(io.carius.lars.ar_flutter_update.R.id.hand_motion_view)
            animatedGuide.doOnPreDraw {
                val travel = animatedGuide.width * 0.28f
                val animator = ObjectAnimator.ofFloat(hand, View.TRANSLATION_X, -travel, travel).apply {
                    duration = 1500L
                    repeatCount = ValueAnimator.INFINITE
                    repeatMode = ValueAnimator.REVERSE
                    interpolator = AccelerateDecelerateInterpolator()
                }
                hand.setTag(io.carius.lars.ar_flutter_update.R.id.hand_motion_view, animator)
                animator.start()
            }
        }

        // Configure feature points
        if (argShowFeaturePoints == true) {
            arSceneView.scene.addChild(pointCloudNode)
            showFeaturePoints = true
        } else {
            showFeaturePoints = false
            while ((pointCloudNode.children?.size ?: 0) > 0) {
                pointCloudNode.children?.first()?.setParent(null)
            }
            pointCloudNode.setParent(null)
        }

        // Configure plane detection
        val config = arSceneView.session?.config
        if (config == null) {
            sessionManagerChannel.invokeMethod("onError", listOf("session is null"))
        }
        when (argPlaneDetectionConfig) {
            1 -> config?.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL
            2 -> config?.planeFindingMode = Config.PlaneFindingMode.VERTICAL
            3 -> config?.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
            else -> config?.planeFindingMode = Config.PlaneFindingMode.DISABLED
        }
        arSceneView.session?.configure(config)

        // Configure whether or not detected planes should be shown
        arSceneView.planeRenderer.isVisible = argShowPlanes == true

        // Custom plane texture
        argCustomPlaneTexturePath?.let {
            val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
            val key: String = loader.getLookupKeyForAsset(it)

            val sampler =
                Texture.Sampler.builder()
                    .setMinFilter(Texture.Sampler.MinFilter.LINEAR)
                    .setWrapMode(Texture.Sampler.WrapMode.REPEAT)
                    .build()
            Texture.builder()
                .setSource(viewContext, Uri.parse(key))
                .setSampler(sampler)
                .build()
                .thenAccept { texture: Texture? ->
                    arSceneView.planeRenderer.material.thenAccept { material: Material ->
                        material.setTexture(PlaneRenderer.MATERIAL_TEXTURE, texture)
                        material.setFloat(PlaneRenderer.MATERIAL_SPOTLIGHT_RADIUS, 10f)
                    }
                }
            arSceneView.scene.addOnUpdateListener { _: FrameTime? ->
                arSceneView.planeRenderer.material.thenAccept { material: Material ->
                    material.setFloat(PlaneRenderer.MATERIAL_SPOTLIGHT_RADIUS, 10f)
                }
            }
        }

        // Configure world origin
        if (argShowWorldOrigin == true) {
            worldOriginNode = modelBuilder.makeWorldOriginNode(viewContext)
            arSceneView.scene.addChild(worldOriginNode)
        } else {
            worldOriginNode.setParent(null)
        }

        // Configure Tap handling
        if (argHandleTaps == true) {
            arSceneView.scene.setOnTouchListener { hitTestResult: HitTestResult, motionEvent: MotionEvent? ->
                onTap(hitTestResult, motionEvent)
            }
        }

        // Configure gestures
        enableRotation = argHandleRotation == true
        enablePans = argHandlePans == true
        if (arEnabledQualityRing==false) {
            // طفي الحلقة الحالية إن وُجدت
            qualityRingParent?.setParent(null)
            qualityRingParent = null
            ringPending = false
            qualityStates.fill(0)
        } else {
            qualityRingEnabled = true
            if (hostingAnchorName != null) {
               // ringPending = true
            }
        }
        if (arDepthOcclusionMode==true) {
            depthOcclusionMode=true
            arSceneView.cameraStream.depthOcclusionMode =
                if (arSceneView.session!!.isDepthModeSupported(Config.DepthMode.AUTOMATIC))
                    CameraStream.DepthOcclusionMode.DEPTH_OCCLUSION_ENABLED
                else
                    CameraStream.DepthOcclusionMode.DEPTH_OCCLUSION_DISABLED
        }
        var needRebuild = false

        arSegmentsQualityRing?.let {
            qualitySegments = it.coerceIn(4, 72) // حدود معقولة
            qualityStates = IntArray(qualitySegments) { 0 }
            needRebuild = true
        }
        arRadiusQualityRing?.let { ringRadiusMeters = it.toFloat().coerceAtLeast(0.1f) ; needRebuild = true }
        arHeightQualityRing?.let { ringHeightMeters = it.toFloat().coerceAtLeast(0.05f); needRebuild = true }
        arColumnWidthQualityRing?.let { ringColumnWidth = it.toFloat().coerceAtLeast(0.01f); needRebuild = true }

        // لو فيه حلقة معروضة الآن، أعد بناءها بالمقاسات الجديدة
        if (needRebuild && qualityRingParent != null && hostingAnchorName != null) {
            val anchorNode = arSceneView.scene.findByName(hostingAnchorName!!) as? AnchorNode
            if (anchorNode?.anchor != null) {
                buildQualityRingAround(anchorNode)
            }
        }
        result.success(null)
    }

    private fun onFrame(frameTime: FrameTime) {
        if (isCameraEnabled) {
            val frame = arSceneView.arFrame
            if (frame != null) {
                for (plane in frame.getUpdatedTrackables(Plane::class.java)) {
                    if (plane.trackingState == TrackingState.TRACKING && !detectedPlanes.contains(plane)) {
                        detectedPlanes.add(plane)
                        planeCount++
                        sessionManagerChannel.invokeMethod("onPlaneDetected", planeCount)
                    }
                }
            }
            // hide instructions view if no longer required
            if (showAnimatedGuide && arSceneView.arFrame != null) {
                for (plane in arSceneView.arFrame!!.getUpdatedTrackables(Plane::class.java)) {
                    if (plane.trackingState === TrackingState.TRACKING) {
                        val root = activity.findViewById<ViewGroup>(android.R.id.content)
                        if (::animatedGuide.isInitialized && animatedGuide.parent === root) {
                            removeGuide(animatedGuide)
                        }
                        showAnimatedGuide = false
                        break
                    }
                }
            }

            if (showFeaturePoints) {
                // remove points from last frame
                while ((pointCloudNode.children?.size ?: 0) > 0) {
                    pointCloudNode.children?.first()?.setParent(null)
                }
                val pointCloud = arSceneView.arFrame?.acquirePointCloud()
                val points = pointCloud?.points ?: FloatBuffer.allocate(0)
                if (points.limit() / 4 >= 1) {
                    for (index in 0 until points.limit() / 4) {
                        val featurePoint =
                            modelBuilder.makeFeaturePointNode(
                                viewContext,
                                points.get(4 * index),
                                points.get(4 * index + 1),
                                points.get(4 * index + 2)
                            )
                        featurePoint.setParent(pointCloudNode)
                    }
                }
                pointCloud?.release()
            }

            // ======= [جديد] إبقاء الحلقة “معلّقة” حتى يظهر العنصر =======
            if (qualityRingEnabled && ringPending && hostingAnchorName != null && matsReady) {
                val anchorNode = arSceneView.scene.findByName(hostingAnchorName!!) as? AnchorNode
                if (anchorNode?.anchor != null && nodeHasAnyRenderable(anchorNode)) {
                    buildQualityRingAround(anchorNode) // الآن نبنيها لأن العنصر صار ظاهر
                    ringPending = false
                }
            }
            // ======= [انتهى الجديد الأول] =======

            // ======= تحديث حلقة الجودة وتلوين الأعمدة والرفع التلقائي =======
            val f = arSceneView.arFrame
            if (qualityRingEnabled && hostingAnchorName != null && f != null && qualityRingParent != null) {
                val anchorNode = arSceneView.scene.findByName(hostingAnchorName!!) as? AnchorNode
                if (anchorNode?.anchor != null && nodeHasAnyRenderable(anchorNode)) {
                    val autoNow = computeAutoRingParams(anchorNode)
                    if (ringParamsChangedSignificantly(lastAutoRing, autoNow)) {
                        ringRadiusMeters = autoNow.radius
                        ringHeightMeters = autoNow.height
                        ringColumnWidth = autoNow.colWidth
                        buildQualityRingAround(anchorNode)
                    }
                }
                if (anchorNode?.anchor != null && qualityRingParent?.parent == anchorNode) {
                    val camPose = f.camera.displayOrientedPose
                    val camWorld = Vector3(camPose.tx(), camPose.ty(), camPose.tz())
                    val anchorPos = anchorNode.worldPosition

                    // تحديد القطاع الحالي
                    val az = azimuthDeg(anchorPos, camWorld)
                    val sector = sectorForAzimuth(az)

                    // تقدير الجودة
                    val q = arSceneView.session?.estimateFeatureMapQualityForHosting(camPose)
                    when (q) {
                        Session.FeatureMapQuality.GOOD -> setColumnState(sector, 2)
                        Session.FeatureMapQuality.SUFFICIENT -> setColumnState(sector, 1)
                        Session.FeatureMapQuality.INSUFFICIENT, null -> { /* لا شيء */ }
                    }

                    // تأثير مجاور خفيف
                    if (q == Session.FeatureMapQuality.GOOD) {
                        val left = (sector - 1 + qualitySegments) % qualitySegments
                        val right = (sector + 1) % qualitySegments
                        setColumnState(left, 1)
                        setColumnState(right, 1)
                    }

                    // رفع تلقائي عند الاكتمال
                    val avgQuality = computeOverallQuality()
                    if (!hostingTriggered && avgQuality >= 0.6f) { // غير 0.8 حسب العتبة اللي تناسبك
                        hostingTriggered = true
                        autoHostCloudAnchor(anchorNode)
                    }
                }
            }
            // ======= [انتهى الجديد الثاني] =======
        }

        val frame = arSceneView.arFrame
        val updatedAnchors = frame?.updatedAnchors ?: emptyList()
        if (this::cloudAnchorHandler.isInitialized) {
            cloudAnchorHandler.onUpdate(updatedAnchors)
        }

        if (isCameraEnabled) {
            if (keepNodeSelected && transformationSystem.selectedNode != null && transformationSystem.selectedNode!!.isTransforming) {
                keepNodeSelected = false
            }
            if (!keepNodeSelected && transformationSystem.selectedNode != null && !transformationSystem.selectedNode!!.isTransforming) {
                transformationSystem.selectNode(null)
                keepNodeSelected = true
            }
            if (!enablePans && !enableRotation) {
                transformationSystem.selectNode(null)
            }
        }
    }

    private fun addNode(
        dict_node: HashMap<String, Any>,
        dict_anchor: HashMap<String, Any>? = null
    ): CompletableFuture<Boolean> {
        val completableFutureSuccess: CompletableFuture<Boolean> = CompletableFuture()
        try {
            when (dict_node["type"] as Int) {
                0 -> { // GLTF2 from Flutter assets
                    val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
                    val key: String = loader.getLookupKeyForAsset(dict_node["uri"] as String)

                    modelBuilder.makeNodeFromGltf(
                        viewContext,
                        transformationSystem,
                        objectManagerChannel,
                        enablePans,
                        enableRotation,
                        dict_node["name"] as String,
                        key,
                        dict_node["transformation"] as ArrayList<Double>
                    ).thenAccept { node ->
                        val anchorName: String? = dict_anchor?.get("name") as? String
                        val anchorType: Int? = dict_anchor?.get("type") as? Int
                        if (anchorName != null && anchorType != null) {
                            val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
                            if (anchorNode != null) {
                                anchorNode.addChild(node)
                                completableFutureSuccess.complete(true); return@thenAccept
                            } else {
                                completableFutureSuccess.complete(false); return@thenAccept
                            }
                        } else {
                            arSceneView.scene.addChild(node)
                            completableFutureSuccess.complete(true); return@thenAccept
                        }
                    }.exceptionally { throwable ->
                        val mainHandler = Handler(viewContext.mainLooper)
                        val runnable = Runnable {
                            sessionManagerChannel.invokeMethod(
                                "onError",
                                listOf("Unable to load renderable" + dict_node["uri"] as String)
                            )
                        }
                        mainHandler.post(runnable)
                        completableFutureSuccess.completeExceptionally(throwable)
                        null
                    }
                }
                1 -> { // GLB from web
                    modelBuilder.makeNodeFromGlb(
                        viewContext,
                        transformationSystem,
                        objectManagerChannel,
                        enablePans,
                        enableRotation,
                        dict_node["name"] as String,
                        dict_node["uri"] as String,
                        dict_node["transformation"] as ArrayList<Double>
                    ).thenAccept { node ->

                        val anchorName: String? = dict_anchor?.get("name") as? String
                        val anchorType: Int? = dict_anchor?.get("type") as? Int

                        if (anchorName != null && anchorType != null) {
                            val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
                            if (anchorNode != null) {
                                anchorNode.addChild(node)
                                applyGroundBiasIfNeeded(node /*, 0.015f أو 0.02f حسب ما يلائمك */)
                                completableFutureSuccess.complete(true); return@thenAccept
                            } else {
                                completableFutureSuccess.complete(false); return@thenAccept
                            }
                        } else {
                            arSceneView.scene.addChild(node)
                            applyGroundBiasIfNeeded(node /*, 0.015f أو 0.02f حسب ما يلائمك */)
                            completableFutureSuccess.complete(true); return@thenAccept
                        }

                    }.exceptionally { throwable ->
                        val mainHandler = Handler(viewContext.mainLooper)
                        val runnable = Runnable {
                            sessionManagerChannel.invokeMethod(
                                "onError",
                                listOf("Unable to load renderable ${dict_node["uri"]}: ${throwable?.message}")
                            )

                        }
                        mainHandler.post(runnable)
                        completableFutureSuccess.completeExceptionally(throwable)
                        null
                    }
                }
                2 -> { // fileSystemAppFolderGLB
                    val documentsPath = viewContext.applicationInfo.dataDir
                    val assetPath = "$documentsPath/app_flutter/${dict_node["uri"] as String}"

                    modelBuilder.makeNodeFromGlb(
                        viewContext,
                        transformationSystem,
                        objectManagerChannel,
                        enablePans,
                        enableRotation,
                        dict_node["name"] as String,
                        assetPath,
                        dict_node["transformation"] as ArrayList<Double>
                    ).thenAccept { node ->
                        val anchorName: String? = dict_anchor?.get("name") as? String
                        val anchorType: Int? = dict_anchor?.get("type") as? Int
                        if (anchorName != null && anchorType != null) {
                            val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
                            if (anchorNode != null) {
                                anchorNode.addChild(node)
                                completableFutureSuccess.complete(true); return@thenAccept
                            } else {
                                completableFutureSuccess.complete(false); return@thenAccept
                            }
                        } else {
                            arSceneView.scene.addChild(node)
                            completableFutureSuccess.complete(true); return@thenAccept
                        }
                    }.exceptionally { throwable ->
                        val mainHandler = Handler(viewContext.mainLooper)
                        val runnable = Runnable {
                            sessionManagerChannel.invokeMethod(
                                "onError",
                                listOf("Unable to load renderable " + dict_node["uri"] as String)
                            )
                        }
                        mainHandler.post(runnable)
                        completableFutureSuccess.completeExceptionally(throwable)
                        null
                    }
                }
                3 -> { // fileSystemAppFolderGLTF2
                    val documentsPath = viewContext.applicationInfo.dataDir
                    val assetPath = "$documentsPath/app_flutter/${dict_node["uri"] as String}"

                    modelBuilder.makeNodeFromGltf(
                        viewContext,
                        transformationSystem,
                        objectManagerChannel,
                        enablePans,
                        enableRotation,
                        dict_node["name"] as String,
                        assetPath,
                        dict_node["transformation"] as ArrayList<Double>
                    ).thenAccept { node ->
                        val anchorName: String? = dict_anchor?.get("name") as? String
                        val anchorType: Int? = dict_anchor?.get("type") as? Int
                        if (anchorName != null && anchorType != null) {
                            val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
                            if (anchorNode != null) {
                                anchorNode.addChild(node)
                                completableFutureSuccess.complete(true); return@thenAccept
                            } else {
                                completableFutureSuccess.complete(false); return@thenAccept
                            }
                        } else {
                            arSceneView.scene.addChild(node)
                            completableFutureSuccess.complete(true); return@thenAccept
                        }
                    }.exceptionally { throwable ->
                        val mainHandler = Handler(viewContext.mainLooper)
                        val runnable = Runnable {
                            sessionManagerChannel.invokeMethod(
                                "onError",
                                listOf("Unable to load renderable" + dict_node["uri"] as String)
                            )
                        }
                        mainHandler.post(runnable)
                        completableFutureSuccess.completeExceptionally(throwable)
                        null
                    }
                }
                else -> {
                    completableFutureSuccess.complete(false)
                }
            }
        } catch (e: Exception) {
            completableFutureSuccess.completeExceptionally(e)
        }

        return completableFutureSuccess
    }

    private fun transformNode(name: String, transform: ArrayList<Double>) {
        val node = arSceneView.scene.findByName(name)
        node?.let {
            val currentLocalPos = node.localPosition
            val (scale, position, rotation) = deserializeMatrix4s(transform)
            it.localScale = scale
            it.localPosition = position
            it.localRotation = currentLocalPos
        }
    }

    private fun onTap(hitTestResult: HitTestResult, motionEvent: MotionEvent?): Boolean {
        val frame = arSceneView.arFrame
        if (hitTestResult.node != null && motionEvent?.action == MotionEvent.ACTION_DOWN) {
            objectManagerChannel.invokeMethod("onNodeTap", listOf(hitTestResult.node?.name))
            return true
        }
        if (motionEvent != null && motionEvent.action == MotionEvent.ACTION_DOWN) {
            if (transformationSystem.selectedNode == null || (!enablePans && !enableRotation)) {
                val allHitResults = frame?.hitTest(motionEvent) ?: listOf<HitResult>()
                val planeAndPointHitResults =
                    allHitResults.filter { ((it.trackable is Plane) || (it.trackable is Point)) }
                val serializedPlaneAndPointHitResults: ArrayList<HashMap<String, Any>> =
                    ArrayList(planeAndPointHitResults.map { serializeHitResult(it) })
                sessionManagerChannel.invokeMethod(
                    "onPlaneOrPointTap",
                    serializedPlaneAndPointHitResults
                )
                return true
            } else {
                return false
            }
        }
        return false
    }

    private fun addPlaneAnchor(transform: ArrayList<Double>, name: String): Boolean {
        return try {
            val (scale, position, rotation) = deserializeMatrix4s(transform)
            val pos = floatArrayOf(position.x, position.y, position.z)
            val rot = floatArrayOf(rotation.x, rotation.y, rotation.z, rotation.w)
            val anchor: Anchor = arSceneView.session!!.createAnchor(Pose(pos, rot))
            val anchorNode = AnchorNode(anchor).apply {
                this.name = name
                setParent(arSceneView.scene)
            }

            hostingTriggered = false

            // نظّف أي حلقة قديمة
            qualityRingParent?.setParent(null)
            qualityRingParent = null
            qualityStates.fill(0)

            // لو الحلقة مفعّلة، انتظر ظهور المجسّم ثم ابنيها في onFrame
            ringPending = qualityRingEnabled

            true
        } catch (e: Exception) {
            false
        }
    }

    private fun removeGuide(viewToRemove: View?) {
        if (viewToRemove == null) return

        (viewToRemove.getTag(
            io.carius.lars.ar_flutter_update.R.id.hand_motion_view
        ) as? ObjectAnimator)?.cancel()

        viewToRemove.findViewById<View>(
            io.carius.lars.ar_flutter_update.R.id.hand_motion_view
        )?.let { hand ->
            hand.animate().cancel()
            hand.clearAnimation()
            (hand.getTag(
                io.carius.lars.ar_flutter_update.R.id.hand_motion_view
            ) as? ObjectAnimator)?.cancel()
        }

        viewToRemove.clearAnimation()
        (viewToRemove.parent as? ViewGroup)?.removeView(viewToRemove)
    }

    private fun removeAnchor(name: String) {
        val anchorNode = arSceneView.scene.findByName(name) as AnchorNode?
        anchorNode?.let {
            anchorNode.anchor?.detach()
            for (node in anchorNode.children) {
                if (transformationSystem.selectedNode?.name == node.name) {
                    transformationSystem.selectNode(null)
                    keepNodeSelected = true
                }
                node.setParent(null)
            }
            anchorNode.setParent(null)
        }
    }

    private fun ensureSunLight(intensityLux: Float = 120_000f) {
        if (isDisposed) return
        try {
            if (sunNode == null) {
                sunNode = Node().apply {
                    light = Light.builder(Light.Type.DIRECTIONAL)
                        .setColor(Color(1f, 1f, 1f))
                        .setIntensity(intensityLux)
                        .setShadowCastingEnabled(true)
                        .build()
                    localRotation = com.google.ar.sceneform.math.Quaternion.axisAngle(Vector3(1f, 0f, 0f), -45f)
                }
                arSceneView.scene.addChild(sunNode)
            } else {
                sunNode?.light?.intensity = intensityLux
            }
        } catch (e: IllegalStateException) {
            Log.w(TAG, "ensureSunLight after Engine destroyed; ignoring")
        }
    }

    private inner class cloudAnchorUploadedListener : CloudAnchorHandlers.CloudAnchorListener {
        override fun onCloudTaskComplete(anchorName: String?, anchor: Anchor?) {
            val cloudState = anchor!!.cloudAnchorState
            if (cloudState.isError) {
                Log.e(TAG, "Error uploading anchor, state $cloudState")
                sessionManagerChannel.invokeMethod("onError", listOf("Error uploading anchor, state $cloudState"))
                return
            }
            val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
            val oldAnchor = anchorNode?.anchor
            anchorNode?.anchor = anchor
            oldAnchor?.detach()

            val args = HashMap<String, String?>()
            args["name"] = anchorName
            args["cloudanchorid"] = anchor.cloudAnchorId
            anchorManagerChannel.invokeMethod("onCloudAnchorUploaded", args)
        }
    }
    private inner class autoCloudAnchorUploadedListener : CloudAnchorHandlers.CloudAnchorListener {
        override fun onCloudTaskComplete(anchorName: String?, anchor: Anchor?) {
            val cloudState = anchor!!.cloudAnchorState
            if (cloudState.isError) {
                Log.e(TAG, "Error uploading anchor, state $cloudState")
                anchorManagerChannel.invokeMethod("autoHostCloudAnchorStarted", false)
                sessionManagerChannel.invokeMethod("onError", listOf("Error uploading anchor, state $cloudState"))
                return
            }
            val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
            val oldAnchor = anchorNode?.anchor
            anchorNode?.anchor = anchor
            oldAnchor?.detach()

            val args = HashMap<String, String?>()
            args["name"] = anchorName
            args["cloudanchorid"] = anchor.cloudAnchorId
            anchorManagerChannel.invokeMethod("autoHostCloudAnchor", args)
        }
    }

    private inner class cloudAnchorDownloadedListener : CloudAnchorHandlers.CloudAnchorListener {
        override fun onCloudTaskComplete(anchorName: String?, anchor: Anchor?) {
            val cloudState = anchor!!.cloudAnchorState
            if (cloudState.isError) {
                Log.e(TAG, "Error downloading anchor, state $cloudState")
                sessionManagerChannel.invokeMethod("onError", listOf("Error downloading anchor, state $cloudState"))
                return
            }
            val newAnchorNode = AnchorNode(anchor)
            anchorManagerChannel.invokeMethod(
                "onAnchorDownloadSuccess",
                serializeAnchor(newAnchorNode, anchor),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        newAnchorNode.name = result.toString()
                        newAnchorNode.setParent(arSceneView.scene)
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        sessionManagerChannel.invokeMethod(
                            "onError",
                            listOf("Error while registering downloaded anchor at the AR Flutter plugin: $errorMessage")
                        )
                    }

                    override fun notImplemented() {
                        sessionManagerChannel.invokeMethod(
                            "onError",
                            listOf("Error while registering downloaded anchor at the AR Flutter plugin")
                        )
                    }
                }
            )
        }
    }

    private val mainHandler = Handler(android.os.Looper.getMainLooper())

    private fun shouldRetry(state: Anchor.CloudAnchorState): Boolean {
        return when (state) {
            Anchor.CloudAnchorState.TASK_IN_PROGRESS,
            Anchor.CloudAnchorState.ERROR_INTERNAL,
            Anchor.CloudAnchorState.ERROR_RESOURCE_EXHAUSTED,
            Anchor.CloudAnchorState.ERROR_SERVICE_UNAVAILABLE -> true
            else -> false
        }
    }

    private fun resolveCloudAnchorWithRetry(
        anchorId: String,
        attempt: Int = 0,
        maxRetries: Int = 5,
        baseDelayMs: Long = 750L
    ) {
//        sessionManagerChannel.invokeMethod(
//            "onCloudAnchorResolveAttempt",
//            listOf(anchorId, attempt, maxRetries)
//        )

        cloudAnchorHandler.resolveCloudAnchor(anchorId, object : CloudAnchorHandlers.CloudAnchorListener {
            override fun onCloudTaskComplete(anchorName: String?, anchor: Anchor?) {
                Log.w(TAG, "done down Anchor $anchorName  cloudAnchorState: ${anchor?.cloudAnchorState}")
                if (anchor == null) {
                    if (attempt < maxRetries) {
                        val nextDelay = baseDelayMs * (1 shl attempt)
                        Log.w(TAG, "Anchor is null, retry #${attempt + 1} in ${nextDelay}ms")
                        mainHandler.postDelayed({
                            resolveCloudAnchorWithRetry(anchorId, attempt + 1, maxRetries, baseDelayMs)
                        }, nextDelay)
                    } else {
                        val msg = "Error downloading anchor: null anchor after $maxRetries attempts"
                        Log.e(TAG, msg)
                        sessionManagerChannel.invokeMethod("onError", listOf(msg))
                    }
                    return
                }

                val cloudState = anchor.cloudAnchorState
                if (cloudState.isError) {
                    if (shouldRetry(cloudState) && attempt < maxRetries) {
                        val nextDelay = baseDelayMs * (1 shl attempt)
                        Log.w(TAG, "Resolve state=$cloudState, retry #${attempt + 1} in ${nextDelay}ms")
                        mainHandler.postDelayed({
                            try { anchor.detach() } catch (_: Exception) {}
                            resolveCloudAnchorWithRetry(anchorId, attempt + 1, maxRetries, baseDelayMs)
                        }, nextDelay)
                    } else {
                        val msg = "Error downloading anchor, state $cloudState (attempts=$attempt)"
                        Log.e(TAG, msg)
                        sessionManagerChannel.invokeMethod("onError", listOf(msg))
                    }
                    return
                }

                val newAnchorNode = AnchorNode(anchor)
                anchorManagerChannel.invokeMethod(
                    "onAnchorDownloadSuccess",
                    serializeAnchor(newAnchorNode, anchor),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            Log.w(TAG, "done down newAnchorNode $result  cloudAnchorState: ${anchor.cloudAnchorState}")
                            newAnchorNode.name = result.toString()
                            newAnchorNode.setParent(arSceneView.scene)
                        }

                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                            sessionManagerChannel.invokeMethod(
                                "onError",
                                listOf("Error while registering downloaded anchor at the AR Flutter plugin: $errorMessage")
                            )
                        }

                        override fun notImplemented() {
                            sessionManagerChannel.invokeMethod(
                                "onError",
                                listOf("Error while registering downloaded anchor at the AR Flutter plugin")
                            )
                        }
                    }
                )
            }
        })
    }

    private fun buildQualityRingAround(anchorNode: AnchorNode) {
        // ==== [MODIFY] احسب بارامترات الحلقة من حجم الجسم لتقليل المسافة وتكييف الأعمدة ====
        val auto = computeAutoRingParams(anchorNode)
        ringRadiusMeters = auto.radius
        ringHeightMeters = auto.height
        ringColumnWidth = auto.colWidth
        lastAutoRing = auto
        // =======================================

        // إزالة قديم
        qualityRingParent?.setParent(null)
        qualityRingParent = Node().apply { setParent(anchorNode) }

        // إعادة ضبط الحالات
        for (i in qualityStates.indices) qualityStates[i] = 0

        if (!matsReady) return

        val stepDeg = 360f / qualitySegments
        for (i in 0 until qualitySegments) {
            val angleRad = Math.toRadians((i * stepDeg).toDouble())
            val x = (ringRadiusMeters * Math.cos(angleRad)).toFloat()
            val z = (ringRadiusMeters * Math.sin(angleRad)).toFloat()

            val col = Node().apply {
                setParent(qualityRingParent)
                localPosition = Vector3(x, ringHeightMeters / 2f, z)

                val cyl = ShapeFactory.makeCylinder(
                    ringColumnWidth,
                    ringHeightMeters,
                    Vector3(0f, 0f, 0f),
                    matRed
                )
                renderable = cyl

                localRotation = com.google.ar.sceneform.math.Quaternion.lookRotation(
                    Vector3(-x, 0f, -z),
                    Vector3.up()
                )
                name = "quality_col_$i"
            }
        }
    }


    // CHANGED: تلوين العمود الصحيح حتى مع القوس الجزئي (نصل له بالاسم لا بفهرس children)
    private fun setColumnState(index: Int, state: Int) {
        // لا ننزل حالة عمود من GOOD إلى أضعف
        if (state <= qualityStates.getOrElse(index) { 0 }) return
        qualityStates[index] = state

        val colName = "quality_col_$index"
        val node = qualityRingParent?.children
            ?.firstOrNull { it.name == colName } as? Node ?: return

        val chosenMat = when (state) {
            2 -> matGreen
            1 -> matYellow
            else -> matRed
        }
        (node.renderable as? ModelRenderable)?.material = chosenMat
    }


    private fun computeOverallQuality(): Float {
        var sum = 0f
        for (state in qualityStates) {
            when (state) {
                1 -> sum += 0.6f   // SUFFICIENT
                2 -> sum += 1.0f   // GOOD
            }
        }
        return if (qualityStates.isNotEmpty()) {
            sum / qualityStates.size.toFloat()
        } else {
            0f
        }
    }

    private fun azimuthDeg(from: Vector3, to: Vector3): Float {
        val dx = to.x - from.x
        val dz = to.z - from.z
        var deg = Math.toDegrees(Math.atan2(dz.toDouble(), dx.toDouble())).toFloat()
        if (deg < 0) deg += 360f
        return deg
    }

    private fun sectorForAzimuth(deg: Float): Int {
        val step = 360f / qualitySegments
        val idx = Math.floor((deg / step).toDouble()).toInt()
        return idx.coerceIn(0, qualitySegments - 1)
    }
    private fun autoHostCloudAnchor(anchorNode: AnchorNode) {
        // إن لم تكن وضعت cloud mode: فعلّه أولاً عبر نداء initGoogleCloudAnchorMode من طرف Flutter
        try {
            val session = arSceneView.session ?: return
            // تأكد جودة ممتازة قبل الرفع (ليست ضرورية إن كنا وصلنا allGood)
            val quality = session.estimateFeatureMapQualityForHosting(arSceneView.arFrame?.camera?.displayOrientedPose)
            if (quality != Session.FeatureMapQuality.GOOD) {
                // احتياط: لا ترفع لو الجودة انخفضت فجأة لهذا الفريم
                hostingTriggered = false
                return
            }
            if (!this::cloudAnchorHandler.isInitialized) {
                sessionManagerChannel.invokeMethod("onError", listOf("Cloud mode not initialized. Call initGoogleCloudAnchorMode first"))
                hostingTriggered = false
                return
            }

            // ارفع الـ Anchor الحالي
            anchorManagerChannel.invokeMethod("autoHostCloudAnchorStarted", true)
            cloudAnchorHandler.hostCloudAnchorWithTtl(
                hostingAnchorName ?: "auto_anchor",
                anchorNode.anchor,
                autoCloudAnchorUploadedListener(),
                356
            )
            // ملاحظة: سيصل إشعار النجاح عبر onCloudAnchorUploaded
        } catch (e: Exception) {
            hostingTriggered = false
            sessionManagerChannel.invokeMethod("onError", listOf("Auto host failed: ${e.message}"))
        }
    }
    private fun nodeHasAnyRenderable(node: Node?): Boolean {
        if (node == null) return false
        if (node.renderable != null) return true
        val kids = node.children ?: return false
        for (child in kids) {
            if (nodeHasAnyRenderable(child)) return true
        }
        return false
    }
    // ==== [ADD] Helpers to estimate object bounds in meters ====
    private data class RingParams(val radius: Float, val height: Float, val colWidth: Float)
    private var lastAutoRing: RingParams? = null

    private fun getRenderableWorldSizeMeters(renderable: Renderable, node: Node): Vector3 {
        // نحاول استخدام CollisionShape لو متاح (Box)
        try {
            val shape = (renderable as? ModelRenderable)?.collisionShape
            if (shape is Box) {
                // Box.size هي الأبعاد الكاملة (وليس نصفها)
                val size = shape.size
                val s = node.worldScale
                return Vector3(size.x * s.x, size.y * s.y, size.z * s.z)
            }
        } catch (_: Exception) { /* fallback */ }
        // fallback: نفترض 1m * scale (كحد أدنى معقول)
        val s = node.worldScale
        return Vector3(1f * s.x, 1f * s.y, 1f * s.z)
    }

    private fun estimateAnchorObjectBounds(anchorNode: AnchorNode): Vector3 {
        // ندمج كل أحجام الـ renderables تحت الـ anchor ونأخذ الأكبر
        var maxX = 0f; var maxY = 0f; var maxZ = 0f

        fun dfs(n: Node) {
            n.renderable?.let { r ->
                val sz = getRenderableWorldSizeMeters(r, n)
                maxX = maxOf(maxX, sz.x)
                maxY = maxOf(maxY, sz.y)
                maxZ = maxOf(maxZ, sz.z)
            }
            n.children?.forEach { dfs(it) }
        }
        dfs(anchorNode)
        // في حال لا يوجد Renderable بعد، رجّع قيمة صغيرة لتجنب division by zero
        if (maxX == 0f && maxY == 0f && maxZ == 0f) return Vector3(0.3f, 0.3f, 0.3f)
        return Vector3(maxX, maxY, maxZ)
    }

    /**
     * يحسب بارامترات الحلقة تلقائيًا من حجم الجسم:
     * - نصف القطر قريب من الجسم (يقلل المسافة الكبيرة).
     * - ارتفاع الأعمدة ~ نصف ارتفاع الجسم.
     * - عرض العمود نسبة من نصف القطر.
     */
    // أصغر وأقرب للعنصر
    private fun computeAutoRingParams(anchorNode: AnchorNode): RingParams {
        val sz = estimateAnchorObjectBounds(anchorNode)
        val maxHoriz = maxOf(sz.x, sz.z)
        val objectRadius = (maxHoriz * 0.5f).coerceAtLeast(0.05f)
        val objectHeight = sz.y.coerceAtLeast(0.05f)

        val radius   = (objectRadius * 1.02f).coerceIn(0.05f, 2.0f)

        val height   = (objectHeight * 0.28f).coerceIn(0.04f, 0.8f)

        val colWidth = (radius * 0.05f).coerceIn(0.008f, 0.08f)

        return RingParams(radius, height, colWidth)
    }


    private fun ringParamsChangedSignificantly(a: RingParams?, b: RingParams): Boolean {
        if (a == null) return true
        fun diff(x: Float, y: Float) = kotlin.math.abs(x - y) / (kotlin.math.max(0.0001f, x))
        return diff(a.radius, b.radius) > 0.12f || diff(a.height, b.height) > 0.15f || diff(a.colWidth, b.colWidth) > 0.15f
    }
    fun enqueueResolve(id: String) {
        resolveQueue.addLast(id)
        if (!resolving) processNextResolve()
    }

    private fun processNextResolve() {
        val next = resolveQueue.removeFirstOrNull() ?: run { resolving = false; return }
        resolving = true
        Log.d(TAG, "$next processNextResolve")

        resolveCloudAnchorWithRetry(next)  // الدالة الحالية تنتهي داخل listener

        mainHandler.postDelayed({ processNextResolve() }, 200L)
    }
    // NEW: يرفع المجسّم شعرة فوق الأرض لتقليل القطع من القاعدة
    // NEW: يرفع المجسّم شعرة فوق الأرض إذا كان Pivot عند القاعدة
    private fun applyGroundBiasIfNeeded(node: Node, biasMeters: Float = 0.04f) {
        val r = node.renderable ?: return
        val box = (r.collisionShape as? com.google.ar.sceneform.collision.Box) ?: return

        val size = box.size
        val center = box.center
        val halfH = size.y * 0.5f

        // Pivot عند القاعدة تقريبياً إذا center.y ≈ -halfH
        val pivotAtBase = kotlin.math.abs(center.y + halfH) < 1e-2f
        if (pivotAtBase) {
            node.localPosition = Vector3(
                node.localPosition.x,
                node.localPosition.y + biasMeters,
                node.localPosition.z
            )
        }
    }


}
