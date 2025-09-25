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

    // يمنع نفس الـ URL من التحميل أكثر من مرة بالتوازي
    private var inflight = [String: PassthroughSubject<SCNNode?, Never>]()
    private let inflightQueue = DispatchQueue(label: "GlbRenderableLoader.inflight", attributes: .concurrent)

    // كاش محلي في Caches/
    private lazy var cacheDir: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("glb_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    /// تحميل GLB كـ SCNNode:
    /// - modelPath: http/https أو مسار ملف محلي
    /// - transformation: مصفوفة 4x4 (نفس ما تستخدمه في project) (اختياري)
    /// - targetSize: لتطبيع المقاس إن أردت (اختياري)
    func load(
    name: String,
    modelPath: String,
    transformation: [NSNumber]? = nil,
    targetSize: Float? = nil,
    maxRetries: Int = 2
    ) -> Future<SCNNode?, Never> {

        return Future { promise in
            // إن كان هناك تحميل جارٍ لنفس المفتاح… اشترك فيه بدل بدء واحد جديد
            let key = modelPath
            self.inflightQueue.sync {
                if let existing = self.inflight[key] {
                    existing.sink(receiveCompletion: { _ in },
                        receiveValue: { promise(.success($0)) })
                    .cancel() // لا نحتاج الاحتفاظ بالـ AnyCancellable هنا
                    return
                }
            }

            let subject = PassthroughSubject<SCNNode?, Never>()
            self.inflightQueue.async(flags: .barrier) {
                self.inflight[key] = subject
            }

            // شغّل المهمة بالخلفية
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
                        let url: URL
                        if modelPath.hasPrefix("http://") || modelPath.hasPrefix("https://") {
                            url = try self.downloadToCache(from: modelPath)
                        } else if modelPath.hasPrefix("file://") {
                            url = URL(string: modelPath)!
                        } else {
                            url = URL(fileURLWithPath: modelPath)
                        }

                        // بناء الـ Scene/Node من GLB
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
                        case .failure:
                            if attempt < maxRetries {
                                attempt += 1
                                // backoff بسيط
                                let delay = UInt64(300 * attempt) * 1_000_000
                                usleep(useconds_t(delay / 1000)) // usleep يأخذ microseconds
                                tryAttempt()
                            } else {
                                finish(nil)
                            }
                        }
                    }
                }

                tryAttempt()
            }

            // رجّع نتيجة هذا الـ subject أيضاً لهذا الـ Future
            subject.sink(receiveCompletion: { _ in },
                receiveValue: { promise(.success($0)) })
            .cancel()
        }
    }

    // MARK: - Helpers

    private func hashedFilename(for urlString: String) -> String {
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

        let data = try Data(contentsOf: remote) // بسيط ومباشر؛ إن أردت التبديل لـ URLSession.downloadTask لاحقًا
        try data.write(to: tmp, options: .atomic)

        // تحقق من الحجم
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
        let sceneSource = GLTFSceneSource(url: url)
        let scene = try sceneSource.scene()

        let root = SCNNode()
        root.name = name

        // أضف كل الأطفال كما هي (لا نفلّتنها لتجنب فقدان الهيكلة/الأنيمشين)
        for child in scene.rootNode.childNodes {
            root.addChildNode(child)
        }

        // طبّق التحويل لو وصل من Flutter (نفس النمط في iOS الحالية)
        if let transform = transformation {
            // هذه الدالة متوفرة لديك مسبقًا في المشروع وتُستخدم بكثرة:
            root.transform = deserializeMatrix4(transform)
        }

        // لو تحتاج ضبط حجم موحّد
        if let target = targetSize {
            scaleNodeToUniformSize(root, targetSize: target)
        }

        return root
    }
}
