import Foundation
import ARKit
import GLTFSceneKit
import Combine
import UIKit

/// iOS GLB loader with: caching, in-flight de-dup, limited parallelism, and retries.
/// API مريحة تشبه Android GlbRenderableLoader.load(...)
final class GlbRenderableLoader {

    static let shared = GlbRenderableLoader()

    // حدّ التوازي (مشابه لـ gate في أندرويد)
    private let gate = DispatchSemaphore(value: 3)

    // يمنع نفس الـ URL/المعلمات من التحميل أكثر من مرة بالتوازي
    private var inflight = [String: PassthroughSubject<SCNNode?, Never>]()
    private let inflightQueue = DispatchQueue(label: "GlbRenderableLoader.inflight", attributes: .concurrent)

    // نحتفظ بالـ AnyCancellable للاشتراكات بدل إلغائها فورًا
    private var bag = Set<AnyCancellable>()

    // كاش محلي في Caches/
    private lazy var cacheDir: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("glb_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    // MARK: - Public API

    /// تحميل GLB كـ SCNNode:
    /// - Parameters:
    ///   - name: اسم النود (للتمييز داخل المشهد)
    ///   - modelPath: http/https أو مسار ملف محلي
    ///   - transformation: مصفوفة 4x4 (اختياري)
    ///   - targetSize: لتطبيع المقاس إن أردت (اختياري)
    ///   - maxRetries: محاولات إعادة التحميل عند الفشل
    func load(
    name: String,
    modelPath: String,
    transformation: [NSNumber]? = nil,
    targetSize: Float? = nil,
    maxRetries: Int = 2
    ) -> Future<SCNNode?, Never> {

        return Future { promise in
            // مفتاح in-flight يضمّ المعلمات المهمة (حتى لا يُعاد استخدام نتيجة غير مناسبة)
            let key: String = {
                var parts = [modelPath]
                if let t = targetSize { parts.append("ts=\(t)") }
                if let trx = transformation { parts.append("tx=\(trx.map { $0.stringValue }.joined(separator: ","))") }
                return parts.joined(separator: "|")
            }()

            // لو فيه تحميل جارٍ لنفس المفتاح → اشترك في نفس الـ subject وارجع
            var existingSubj: PassthroughSubject<SCNNode?, Never>?
            self.inflightQueue.sync {
                existingSubj = self.inflight[key]
            }
            if let existing = existingSubj {
                existing
                .sink(receiveCompletion: { _ in },
                    receiveValue: { promise(.success($0)) })
                .store(in: &self.bag)
                return
            }

            // سجّل in-flight جديد
            let subject = PassthroughSubject<SCNNode?, Never>()
            self.inflightQueue.async(flags: .barrier) {
                self.inflight[key] = subject
            }

            // نفّذ بالخلفية مع حدّ التوازي
            DispatchQueue.global(qos: .userInitiated).async {
                self.gate.wait()

                func finish(_ node: SCNNode?) {
                    // إزالة من inflight + إنهاء
                    self.inflightQueue.async(flags: .barrier) {
                        self.inflight.removeValue(forKey: key)
                    }
                    subject.send(node)
                    subject.send(completion: .finished)
                    promise(.success(node))
                    self.gate.signal()
                }

                var attempt = 0

                func once(completion: @escaping (Result<SCNNode?, Error>) -> Void) {
                    do {
                        // حدّد المصدر (إنترنت/ملف/ملف محلي)
                        let url: URL
                        if modelPath.hasPrefix("http://") || modelPath.hasPrefix("https://") {
                            url = try self.downloadToCache(from: modelPath)
                        } else if modelPath.hasPrefix("file://") {
                            guard let u = URL(string: modelPath) else {
                                throw NSError(domain: "GlbRenderableLoader", code: -2, userInfo: [NSLocalizedDescriptionKey: "Bad file:// URL"])
                            }
                            url = u
                        } else {
                            url = URL(fileURLWithPath: modelPath)
                        }

                        // بناء الـ Node من GLB
                        let node = try self.buildNodeFromGLB(
                            url: url,
                            name: name,
                            transformation: transformation,
                            targetSize: targetSize
                        )

                        completion(.success(node))
                    } catch {
                        completion(.failure(error))
                    }
                }

                func tryAttempt() {
                    once { result in
                        switch result {
                        case .success(let node):
                            finish(node)
                        case .failure(let err):
                            if attempt < maxRetries {
                                attempt += 1
                                // backoff بسيط: 0.3s, 0.6s, 0.9s ...
                                let delaySec = 0.3 * Double(attempt)
                                #if DEBUG
                                print("GlbRenderableLoader retry \(attempt) after \(delaySec)s: \(err.localizedDescription)")
                                #endif
                                Thread.sleep(forTimeInterval: delaySec)
                                tryAttempt()
                            } else {
                                #if DEBUG
                                print("GlbRenderableLoader failed after \(attempt) retries: \(err.localizedDescription)")
                                #endif
                                finish(nil)
                            }
                        }
                    }
                }

                tryAttempt()
            }
        }
    }

    // MARK: - Helpers (Cache / Build)

    private func hashedFilename(for urlString: String) -> String {
        // FNV-like بسيط
        let base = urlString.data(using: .utf8)?.reduce(0, { ($0 &* 16777619) ^ UInt32($1) }) ?? 0
        return "mdl_\(base).glb"
    }

    /// تنزيل إلى الكاش إذا لم يكن موجودًا أو حجمه صفر
    private func downloadToCache(from urlString: String) throws -> URL {
        let file = cacheDir.appendingPathComponent(hashedFilename(for: urlString))
        if FileManager.default.fileExists(atPath: file.path),
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
        (attrs[.size] as? NSNumber)?.intValue ?? 0 > 0 {
            return file
        }

        guard let remote = URL(string: urlString) else {
            throw NSError(domain: "GlbRenderableLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        let tmp = cacheDir.appendingPathComponent(UUID().uuidString + ".dl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // تحميل مباشر (سهل)، تقدر تستبدله بـ URLSession.downloadTask لو حبيت
        let data = try Data(contentsOf: remote)
        try data.write(to: tmp, options: .atomic)

        // Move to final
        let final = file
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)
        return final
    }

    private func buildNodeFromGLB(
    url: URL,
    name: String,
    transformation: [NSNumber]?,
    targetSize: Float?
    ) throws -> SCNNode? {
        // GLTFSceneKit parsing (ممكن بالخلفية)
        let sceneSource = GLTFSceneSource(url: url)
        let scene = try sceneSource.scene()

        // نبني جذر ونضيف تحته الأطفال كما هي (للحفاظ على الهيكلة والأنيميشن)
        let root = SCNNode()
        root.name = name

        for child in scene.rootNode.childNodes {
            root.addChildNode(child)
        }

        // طبّق التحويل لو جاء من Flutter/المشروع
        if let transform = transformation {
            root.transform = deserializeMatrix4(transform)
        }

        // تطبيع الحجم (اختياري)
        if let target = targetSize {
            scaleNodeToUniformSize(root, targetSize: target)
        }

        return root
    }

    // MARK: - Optional Utilities

    /// تحويل Array (16 عنصر) إلى SCNMatrix4 (لو عندك نسخة موجودة، استخدمها)
    private func deserializeMatrix4(_ arr: [NSNumber]) -> SCNMatrix4 {
        guard arr.count == 16 else { return SCNMatrix4Identity }
        func f(_ i: Int) -> Float32 { arr[i].floatValue }
        // نفترض ترتيب column-major (نفس SceneKit)
        return SCNMatrix4(
            m11: f(0),  m12: f(1),  m13: f(2),  m14: f(3),
            m21: f(4),  m22: f(5),  m23: f(6),  m24: f(7),
            m31: f(8),  m32: f(9),  m33: f(10), m34: f(11),
            m41: f(12), m42: f(13), m43: f(14), m44: f(15)
        )
    }

    /// يطبع الموديل لحجم موحّد (أكبر بعد = targetSize)
    func scaleNodeToUniformSize(_ node: SCNNode, targetSize: Float) {
        let (minVec, maxVec) = node.boundingBox
        let width = maxVec.x - minVec.x
        let height = maxVec.y - minVec.y
        let length = maxVec.z - minVec.z

        let maxDimension = max(width, max(height, length))
        if maxDimension <= 0 { return }

        let scale = targetSize / maxDimension
        node.scale = SCNVector3(scale, scale, scale)
    }
}
