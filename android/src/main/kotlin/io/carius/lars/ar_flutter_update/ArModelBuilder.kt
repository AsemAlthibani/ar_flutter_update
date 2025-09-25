package io.carius.lars.ar_flutter_update

import android.content.Context
import com.google.ar.sceneform.Node
import com.google.ar.sceneform.math.Vector3
import com.google.ar.sceneform.math.Quaternion

import java.util.concurrent.CompletableFuture
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.TextView
import com.google.ar.core.*
import com.google.ar.sceneform.rendering.*
import com.google.ar.sceneform.ux.*

import io.carius.lars.ar_flutter_update.Serialization.*

import io.flutter.FlutterInjector
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.AccessController
import com.google.ar.sceneform.rendering.ModelRenderable
import com.google.ar.sceneform.rendering.Renderable
import com.google.ar.sceneform.animation.ModelAnimator
// Responsible for creating Renderables and Nodes
class ArModelBuilders {

    // Creates feature point node
    private  val TAG = "ARFeaturePoint"

    fun makeFeaturePointNode(
        context: Context,
        xPos: Float,
        yPos: Float,
        zPos: Float
    ): Node {
        val featurePoint = Node()

        try {
            // إنشاء الماتريال يتم لا-تزامنيًا
            MaterialFactory.makeOpaqueWithColor(context, Color(android.graphics.Color.YELLOW))
                .thenAccept { material ->
                    try {
                        // مقاس مكعب صغير كنقطة مميّزة
                        val size = Vector3(0.01f, 0.01f, 0.01f)

                        // بننشئ الـ renderable ثم نركّبه على الـ node
                        val cubeRenderable = ShapeFactory.makeCube(
                            size,
                            /* center */ Vector3.zero(), // خليه عند المركز المحلي
                            material
                        ).apply {
                            isShadowCaster = false
                            isShadowReceiver = false
                        }

                        // عيّن الموضع عالميًا على الـ Node نفسه
                        featurePoint.worldPosition = Vector3(xPos, yPos, zPos)
                        featurePoint.renderable = cubeRenderable

                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to create cube renderable", e)
                    }
                }
                .exceptionally { t ->
                    // التقاط أخطاء إنشاء الماتريال
                    Log.e(TAG, "Failed to create material", t)
                    null
                }
        } catch (e: Exception) {
            // أي خطأ متزامن قبل ما يبدأ الـ thenAccept
            Log.e(TAG, "Error scheduling material creation", e)
        }

        // نرجع الـ Node حتى لو الإنشاء اللا-تزامني ما خلص بعد
        return featurePoint
    }

    // Creates a coordinate system model at the world origin (X-axis: red, Y-axis: green, Z-axis:blue)
    // The code for this function is adapted from Alexander's stackoverflow answer (https://stackoverflow.com/questions/48908358/arcore-how-to-display-world-origin-or-axes-in-debug-mode)

    fun makeWorldOriginNode(context: Context): Node {
        val axisSize = 0.1f
        val axisRadius = 0.005f

        val rootNode = Node()
        val xNode = Node()
        val yNode = Node()
        val zNode = Node()

        rootNode.addChild(xNode)
        rootNode.addChild(yNode)
        rootNode.addChild(zNode)

        xNode.worldPosition = Vector3(axisSize / 2, 0f, 0f)
        xNode.worldRotation = Quaternion.axisAngle(Vector3(0f, 0f, 1f), 90f)

        yNode.worldPosition = Vector3(0f, axisSize / 2, 0f)

        zNode.worldPosition = Vector3(0f, 0f, axisSize / 2)
        zNode.worldRotation = Quaternion.axisAngle(Vector3(1f, 0f, 0f), 90f)

        try {
            // X (أحمر)
            MaterialFactory.makeOpaqueWithColor(context, Color(android.graphics.Color.RED))
                .thenAccept { redMat ->
                    try {
                        xNode.renderable = ShapeFactory.makeCylinder(
                            axisRadius, axisSize, Vector3.zero(), redMat
                        ).apply {
                            isShadowCaster = false
                            isShadowReceiver = false
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to create X axis renderable", e)
                    }
                }.exceptionally { t ->
                    Log.e(TAG, "Failed to create red material for X axis", t)
                    null
                }

            // Y (أخضر)
            MaterialFactory.makeOpaqueWithColor(context, Color(android.graphics.Color.GREEN))
                .thenAccept { greenMat ->
                    try {
                        yNode.renderable = ShapeFactory.makeCylinder(
                            axisRadius, axisSize, Vector3.zero(), greenMat
                        ).apply {
                            isShadowCaster = false
                            isShadowReceiver = false
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to create Y axis renderable", e)
                    }
                }.exceptionally { t ->
                    Log.e(TAG, "Failed to create green material for Y axis", t)
                    null
                }

            // Z (أزرق)
            MaterialFactory.makeOpaqueWithColor(context, Color(android.graphics.Color.BLUE))
                .thenAccept { blueMat ->
                    try {
                        zNode.renderable = ShapeFactory.makeCylinder(
                            axisRadius, axisSize, Vector3.zero(), blueMat
                        ).apply {
                            isShadowCaster = false
                            isShadowReceiver = false
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to create Z axis renderable", e)
                    }
                }.exceptionally { t ->
                    Log.e(TAG, "Failed to create blue material for Z axis", t)
                    null
                }
        } catch (e: Exception) {
            // أي أخطاء متزامنة قبل تنفيذ thenAccept
            Log.e(TAG, "Error scheduling axis material/renderable creation", e)
        }

        return rootNode
    }

    // Creates a node form a given gltf model path or URL. The gltf asset loading in Scenform is asynchronous, so the function returns a completable future of type Node
    fun makeNodeFromGltf(context: Context, transformationSystem: TransformationSystem, objectManagerChannel: MethodChannel, enablePans: Boolean, enableRotation: Boolean, name: String, modelPath: String, transformation: ArrayList<Double>): CompletableFuture<CustomTransformableNode> {
        val completableFutureNode: CompletableFuture<CustomTransformableNode> = CompletableFuture()

        val gltfNode = CustomTransformableNode(transformationSystem, objectManagerChannel, enablePans, enableRotation)

        ModelRenderable.builder()
            .setSource(context, Uri.parse(modelPath)) // سواء كان رابط أو ملف محلي
            .setRegistryId(modelPath) // لتجنب إعادة التحميل إذا نفس الموديل
            .build()
            .thenAccept{ renderable ->
                    gltfNode.renderable = renderable
                    gltfNode.name = name
                    val transform = deserializeMatrix4s(transformation)
                    gltfNode.worldScale = transform.first
                    gltfNode.worldPosition = transform.second
                    gltfNode.worldRotation = transform.third
                    completableFutureNode.complete(gltfNode)
                }
                .exceptionally { throwable ->
                    completableFutureNode.completeExceptionally(throwable)
                    null // return null because java expects void return (in java, void has no instance, whereas in Kotlin, this closure returns a Unit which has one instance)
                }

    return completableFutureNode
    }

    // Creates a node form a given glb model path or URL. The gltf asset loading in Sceneform is asynchronous, so the function returns a compleatable future of type Node
    fun makeNodeFromGlb2(context: Context, transformationSystem: TransformationSystem, objectManagerChannel: MethodChannel, enablePans: Boolean, enableRotation: Boolean, name: String, modelPath: String, transformation: ArrayList<Double>): CompletableFuture<CustomTransformableNode> {
        val completableFutureNode: CompletableFuture<CustomTransformableNode> = CompletableFuture()

        val gltfNode = CustomTransformableNode(transformationSystem, objectManagerChannel, enablePans, enableRotation)
        //gltfNode.scaleController.isEnabled = false
        //gltfNode.translationController.isEnabled = false

        /*gltfNode.removeTransformationController(translationController)
        gltfNode.addTra
        val customTranslationController = DragController(
            gltfNode,
            transformationSystem.dragRecognizer,
            objectManagerChannel,
            transformationSystem
        )*/

        ModelRenderable.builder()
            .setSource(context, Uri.parse(modelPath)) // سواء كان رابط أو ملف محلي
            .setRegistryId(modelPath) // لتجنب إعادة التحميل إذا نفس الموديل
            .build()
            .thenAccept{ renderable ->
                    gltfNode.renderable = renderable
                    gltfNode.name = name
                    val transform = deserializeMatrix4s(transformation)
                    gltfNode.worldScale = transform.first
                    gltfNode.worldPosition = transform.second
                    gltfNode.worldRotation = transform.third
                    completableFutureNode.complete(gltfNode)
                }
                .exceptionally{throwable ->
                    completableFutureNode.completeExceptionally(throwable)
                    null // return null because java expects void return (in java, void has no instance, whereas in Kotlin, this closure returns a Unit which has one instance)
                }

        return completableFutureNode
    }
    // Creates a node from a given glb model path or URL
    fun makeNodeFromGlb22222222(
        context: Context,
        transformationSystem: TransformationSystem,
        objectManagerChannel: MethodChannel,
        enablePans: Boolean,
        enableRotation: Boolean,
        name: String,
        modelPath: String,
        transformation: ArrayList<Double>
    ): CompletableFuture<CustomTransformableNode> {

        val completable = CompletableFuture<CustomTransformableNode>()

        try {
            val node = CustomTransformableNode(
                transformationSystem,
                objectManagerChannel,
                enablePans,
                enableRotation
            )

            // helper: يشغّل الأنيميشن لو جاهز، وإلا يرجع false
            fun tryStartAnimationOnce(): Boolean {
                return try {
                    val inst = node.renderableInstance ?: return false
                    if (inst.animationCount != null && inst.animationCount > 0) {
                        inst.animate(true)?.start()
                        true
                    } else {
                        false
                    }
                } catch (e: Exception) {
                    Log.e("AndroidARView", "Failed to start animation", e)
                    false
                }
            }

            // helper: يعمل polling خفيف على المين لوبر لحد ما يجهز
            fun startAnimationWhenReady(timeoutMs: Long = 2000L, intervalMs: Long = 32L) {
                val start = System.currentTimeMillis()
                val handler = android.os.Handler(android.os.Looper.getMainLooper())

                fun tick() {
                    try {
                        if (tryStartAnimationOnce()) return
                        if (System.currentTimeMillis() - start >= timeoutMs) return
                        handler.postDelayed({ tick() }, intervalMs)
                    } catch (e: Exception) {
                        Log.e("AndroidARView", "Animation polling failed", e)
                    }
                }
                handler.post { tick() }
            }

            // محاولة بناء الموديل
            try {
                ModelRenderable.builder()
                    .setSource(context, Uri.parse(modelPath)) // رابط أو مسار محلي
                    .setIsFilamentGltf(true)
                    .setRegistryId(modelPath)
                    .build()
                    .thenAccept { renderable ->
                        try {
                            node.renderable = renderable
                            node.name = name

                            // التحويلات (قد تفشل لو الـ data غير صحيحة)
                            try {
                                val transform = deserializeMatrix4s(transformation)
                                node.worldScale = transform.first
                                node.worldPosition = transform.second
                                node.worldRotation = transform.third
                            } catch (e: Exception) {
                                Log.e("AndroidARView", "Failed to apply transform", e)
                                completable.completeExceptionally(e)
                                return@thenAccept
                            }

                            // جرّب الأنيميشن فورًا، وإلا انتظر جاهزية الـ instance
                            if (!tryStartAnimationOnce()) {
                                startAnimationWhenReady()
                            }

                            completable.complete(node)
                        } catch (e: Exception) {
                            Log.e("AndroidARView", "Error inside thenAccept", e)
                            completable.completeExceptionally(e)
                        }
                    }
                    .exceptionally { t ->
                        Log.e("AndroidARView", "Renderable build failed", t)
                        completable.completeExceptionally(t)
                        null
                    }
            } catch (e: Exception) {
                // أخطاء فورية أثناء تجهيز الـ builder أو Uri أو غيره
                Log.e("AndroidARView", "Builder setup failed", e)
                completable.completeExceptionally(e)
            }

        } catch (e: Exception) {
            // أي خطأ غير متوقّع في الإعداد العام
            Log.e("AndroidARView", "makeNodeFromGlb outer error", e)
            completable.completeExceptionally(e)
        }

        return completable
    }

    fun makeNodeFromGlb(
        context: Context,
        transformationSystem: TransformationSystem,
        objectManagerChannel: MethodChannel,
        enablePans: Boolean,
        enableRotation: Boolean,
        name: String,
        modelPath: String,
        transformation: ArrayList<Double>
    ): CompletableFuture<CustomTransformableNode> {

        val completable = CompletableFuture<CustomTransformableNode>()
        val mainHandler = Handler(Looper.getMainLooper())

        try {
            val node = CustomTransformableNode(
                transformationSystem,
                objectManagerChannel,
                enablePans,
                enableRotation
            )

            // تحميل GLB مباشرة بدون HUD
            GlbRenderableLoader.load(context, modelPath)
                .thenAccept { renderable ->
                    try {
                        node.renderable = renderable
                        node.name = name

                        // --- حساب autoScaleFactor ---
                        var autoScaleFactor = 1.0f
                        try {
                            val shape = renderable.collisionShape
                            if (shape is com.google.ar.sceneform.collision.Box) {
                                val boxSize = shape.size
                                val largestDim = maxOf(boxSize.x, boxSize.y, boxSize.z)

                                val maxSize = 2.0f // مترين
                                if (largestDim > maxSize) {
                                    autoScaleFactor = maxSize / largestDim
                                    Log.i("AndroidARView", "Auto-scale factor = $autoScaleFactor")
                                }
                            }
                        } catch (e: Exception) {
                            Log.e("AndroidARView", "Auto-scale check failed", e)
                        }

                        // --- تطبيق التحويلات من Flutter × autoScaleFactor ---
                        try {
                            val (scale, pos, rot) = deserializeMatrix4s(transformation)
                            node.worldScale = Vector3(
                                scale.x * autoScaleFactor,
                                scale.y * autoScaleFactor,
                                scale.z * autoScaleFactor
                            )
                            node.worldPosition = pos
                            node.worldRotation = rot
                        } catch (e: Exception) {
                            Log.e("AndroidARView", "Failed to apply transform", e)
                            completable.completeExceptionally(e)
                            return@thenAccept
                        }

                        // تشغيل أنيميشن لو متاح
                        val inst = node.renderableInstance
                        if (inst != null && (inst.animationCount ?: 0) > 0) {
                            inst.animate(true)?.start()
                        }

                        completable.complete(node)

                    } catch (e: Exception) {
                        Log.e("AndroidARView", "Error inside thenAccept", e)
                        completable.completeExceptionally(e)
                    }
                }.exceptionally { t ->
                    Log.e("AndroidARView", "Renderable build failed ($modelPath): ${t?.message}", t)
                    completable.completeExceptionally(t)
                    null
                }

        } catch (e: Exception) {
            Log.e("AndroidARView", "makeNodeFromGlb outer error", e)
            completable.completeExceptionally(e)
        }

        return completable
    }


}

class CustomTransformableNode(transformationSystem: TransformationSystem, objectManagerChannel: MethodChannel, enablePans: Boolean, enableRotation: Boolean) :
    TransformableNode(transformationSystem) { //

    private lateinit var customTranslationController: CustomTranslationController

    private lateinit var customRotationController: CustomRotationController

    init {
        // Remove standard controllers
        translationController.isEnabled = false
        rotationController.isEnabled = false
        scaleController.isEnabled = false
        removeTransformationController(translationController)
        removeTransformationController(rotationController)
        removeTransformationController(scaleController)


        // Add custom controllers if needed
        if (enablePans) {
            customTranslationController = CustomTranslationController(
                this,
                transformationSystem.dragRecognizer,
                objectManagerChannel
            )
            addTransformationController(customTranslationController)
        }
        if (enableRotation) {
            customRotationController = CustomRotationController(
                this,
                transformationSystem.twistRecognizer,
                objectManagerChannel
            )
            addTransformationController(customRotationController)
        }
    }
}

class CustomTranslationController(transformableNode: BaseTransformableNode, gestureRecognizer: DragGestureRecognizer, objectManagerChannel: MethodChannel) :
    TranslationController(transformableNode, gestureRecognizer) {

    val platformChannel: MethodChannel = objectManagerChannel

    override fun canStartTransformation(gesture: DragGesture): Boolean {
        platformChannel.invokeMethod("onPanStart", transformableNode.name)
        super.canStartTransformation(gesture)
        return transformableNode.isSelected
    }

    override fun onContinueTransformation(gesture: DragGesture) {
        platformChannel.invokeMethod("onPanChange", transformableNode.name)
        super.onContinueTransformation(gesture)
        }

    override fun onEndTransformation(gesture: DragGesture) {
        val serializedLocalTransformation = serializeLocalTransformation(transformableNode)
        platformChannel.invokeMethod("onPanEnd", serializedLocalTransformation)
        super.onEndTransformation(gesture)
     }
}

class CustomRotationController(transformableNode: BaseTransformableNode, gestureRecognizer: TwistGestureRecognizer, objectManagerChannel: MethodChannel) :
    RotationController(transformableNode, gestureRecognizer) {

    val platformChannel: MethodChannel = objectManagerChannel

    override fun canStartTransformation(gesture: TwistGesture): Boolean {
        platformChannel.invokeMethod("onRotationStart", transformableNode.name)
        super.canStartTransformation(gesture)
        return transformableNode.isSelected
    }

    override fun onContinueTransformation(gesture: TwistGesture) {
        platformChannel.invokeMethod("onRotationChange", transformableNode.name)
        super.onContinueTransformation(gesture)
    }

    override fun onEndTransformation(gesture: TwistGesture) {
        val serializedLocalTransformation = serializeLocalTransformation(transformableNode)
        platformChannel.invokeMethod("onRotationEnd", serializedLocalTransformation)
        super.onEndTransformation(gesture)
     }
}
