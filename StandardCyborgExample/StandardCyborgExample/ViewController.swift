//
//  ViewController.swift
//  StandardCyborgExample
//
//  Copyright © 2019 Standard Cyborg. All rights reserved.
//

import StandardCyborgUI
import StandardCyborgFusion
import UIKit
import os

private let appLog = Logger(subsystem: "io.myfactory.scexample", category: "viewcontroller")

class ViewController: UIViewController {
    @IBOutlet private weak var showScanButton: UIButton!
        
    private var lastScene: SCScene?
    private var lastSceneDate: Date?
    private var lastSceneThumbnail: UIImage?
    private var lastRGBDDumpURL: URL?
    private var scenePreviewVC: ScenePreviewViewController?
    
    private lazy var documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    private lazy var sceneGltfURL = documentsURL.appendingPathComponent("scene.gltf")
    private lazy var sceneUsdzURL = documentsURL.appendingPathComponent("scene.usdz")
    private lazy var scenePlyURL  = documentsURL.appendingPathComponent("scene.ply")
    private lazy var sceneThumbnailURL = documentsURL.appendingPathComponent("scene.png")

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    

    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        showScanButton.layer.borderColor = UIColor.white.cgColor
        showScanButton.imageView?.contentMode = .scaleAspectFill
        
        loadScene()
    }
    
    // MARK: - User Interaction
    
    private static let footScanOnboardingShownKey = "FootScanOnboardingShown_v1"

    @IBAction private func startScanning(_ sender: UIButton) {
        #if targetEnvironment(simulator)
        let alert = UIAlertController(title: "Simulator Unsupported", message: "There is no depth camera available on the iOS Simulator. Please build and run on an iOS device with TrueDepth", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alert, animated: true)
        #else
        if UserDefaults.standard.bool(forKey: Self.footScanOnboardingShownKey) {
            presentScanningController()
        } else {
            presentFootScanOnboarding { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.footScanOnboardingShownKey)
                self?.presentScanningController()
            }
        }
        #endif
    }

    private func presentScanningController() {
        let scanningVC = ScanningViewController()
        scanningVC.delegate = self
        scanningVC.generatesTexturedMeshes = true
        scanningVC.automaticallyStopsOnFailure = false
        scanningVC.dumpsRawFrames = true   // MyFactory B-flow: keep raw RGBD for offline Open3D
        scanningVC.modalPresentationStyle = .fullScreen
        present(scanningVC, animated: true)
    }

    private func presentFootScanOnboarding(completion: @escaping () -> Void) {
        let alert = UIAlertController(
            title: "全腳掃描提示",
            message: """

            建議掃描範圍 (繞 360°):
            • 從腳趾掃到腳跟
            • 兩側 + 腳背都要包到
            • 抬腳離地拍腳底
            • 慢速移動,保持腳一直在畫面中

            按底部快門開始,再按一次結束。
            Mesh 處理完才能 Save。
            """,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "開始掃描", style: .default) { _ in
            completion()
        })
        present(alert, animated: true)
    }
    
    @IBAction private func showScan(_ sender: UIButton) {
        guard let scScene = lastScene else { return }

        let vc = ScenePreviewViewController(scScene: scScene)
        vc.leftButton.addTarget(self, action: #selector(deletePreviewedSceneTapped), for: UIControl.Event.touchUpInside)
        vc.rightButton.addTarget(self, action: #selector(exportPreviewedSceneTapped), for: UIControl.Event.touchUpInside)
        vc.leftButton.setTitle("Delete", for: UIControl.State.normal)
        vc.rightButton.setTitle("Export", for: UIControl.State.normal)
        vc.leftButton.backgroundColor = UIColor(named: "DestructiveAction")
        vc.rightButton.backgroundColor = UIColor(named: "DefaultAction")
        // pageSheet 讓使用者可下拉關閉預覽,不必依賴 Delete
        vc.modalPresentationStyle = UIModalPresentationStyle.pageSheet
        scenePreviewVC = vc
        present(vc, animated: true)
    }

    @objc private func deletePreviewedSceneTapped() {
        deleteScene()
        dismiss(animated: true)
    }

    @objc private func dismissPreviewedScanTapped() {
        dismiss(animated: false)
    }

    @objc private func savePreviewedSceneTapped() {
        guard let previewVC = scenePreviewVC else { return }
        appLog.info("savePreviewedSceneTapped: mesh=\(previewVC.scScene.mesh != nil) dumpURL=\(self.lastRGBDDumpURL?.lastPathComponent ?? "nil")")
        // F3 二次檢查: mesh 還沒生成不應該 save (按鈕本應 disabled,但保險起見)
        guard previewVC.scScene.mesh != nil else {
            appLog.error("Save tapped but mesh is nil — guarding")
            let alert = UIAlertController(title: "Mesh 還沒處理完",
                                          message: "請等到右側按鈕變綠 (✅ Save) 再儲存。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            previewVC.present(alert, animated: true)
            return
        }
        // Log free disk + memory at the moment of Save so we can correlate crashes.
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            appLog.info("free disk before save: \(free.int64Value / (1024 * 1024)) MB")
        }
        let memMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        appLog.info("device physical memory: \(memMB) MB")
        saveScene(scene: previewVC.scScene, thumbnail: previewVC.renderedSceneImage)
        dismiss(animated: true)
    }

    @objc private func exportPreviewedSceneTapped() {
        guard let previewVC = scenePreviewVC else { return }

        // Prefer pre-written USDZ/PLY (saved at Save time when SCMesh was still live).
        // If they don't exist, try to generate them from the in-memory mesh; fall back to
        // sharing the GLTF directly.
        let fm = FileManager.default
        var items: [URL] = []
        if fm.fileExists(atPath: sceneUsdzURL.path) { items.append(sceneUsdzURL) }
        if fm.fileExists(atPath: scenePlyURL.path)  { items.append(scenePlyURL) }

        if items.isEmpty, let mesh = previewVC.scScene.mesh {
            if mesh.writeToUSDZ(atPath: sceneUsdzURL.path) { items.append(sceneUsdzURL) }
            if mesh.writeToPLY(atPath: scenePlyURL.path)   { items.append(scenePlyURL) }
        }

        if items.isEmpty, fm.fileExists(atPath: sceneGltfURL.path) {
            items.append(sceneGltfURL)
        }

        // Also include the raw RGBD dump folder so Open3D can reconstruct offline (B-flow)
        if let dumpURL = lastRGBDDumpURL, fm.fileExists(atPath: dumpURL.path) {
            items.append(dumpURL)
        }

        guard !items.isEmpty else {
            let alert = UIAlertController(title: "找不到可匯出的檔案",
                                          message: "請重新掃描並 Save 後再匯出。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            previewVC.present(alert, animated: true)
            return
        }

        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = previewVC.rightButton
        activity.popoverPresentationController?.sourceRect = previewVC.rightButton.bounds
        previewVC.present(activity, animated: true)
    }
    
    // MARK: - Scene I/O
    
    private func loadScene() {
        if
            FileManager.default.fileExists(atPath: sceneGltfURL.path),
            let gltfAttributes = try? FileManager.default.attributesOfItem(atPath: sceneGltfURL.path),
            let dateCreated = gltfAttributes[FileAttributeKey.creationDate] as? Date
        {
            lastScene = SCScene(gltfAtPath: sceneGltfURL.path)
            lastSceneDate = dateCreated
            lastSceneThumbnail = UIImage(contentsOfFile: sceneThumbnailURL.path)
        }
        
        updateUI()
    }
    
    private func saveScene(scene: SCScene, thumbnail: UIImage?) {
        appLog.info("saveScene start: gltf=\(self.sceneGltfURL.lastPathComponent)")
        scene.writeToGLTF(atPath: sceneGltfURL.path)
        appLog.info("saveScene wrote GLTF (\((try? FileManager.default.attributesOfItem(atPath: self.sceneGltfURL.path)[.size]) as? Int ?? 0) bytes)")

        // Pre-write export-friendly formats while we still hold the live SCMesh — once the
        // user re-enters preview from the thumbnail, scScene is rebuilt from GLTF and its
        // .mesh property becomes nil (SDK limitation), so we can't generate USDZ/PLY then.
        if let mesh = scene.mesh {
            // USDZ is best-effort: SDK now returns NO when texture is missing instead
            // of throwing. PLY is the must-have geometry-only fallback for our pipeline.
            appLog.info("saveScene write USDZ start")
            let usdzOk = mesh.writeToUSDZ(atPath: sceneUsdzURL.path)
            appLog.info("saveScene write USDZ done (ok=\(usdzOk))")
            appLog.info("saveScene write PLY start")
            let plyOk = mesh.writeToPLY(atPath: scenePlyURL.path)
            appLog.info("saveScene write PLY done (ok=\(plyOk))")
        } else {
            appLog.error("saveScene: scene.mesh is nil — skipped USDZ/PLY")
        }

        if let thumbnail = thumbnail, let pngData = thumbnail.pngData() {
            try? pngData.write(to: sceneThumbnailURL)
            appLog.info("saveScene wrote thumbnail")
        }

        lastScene = scene
        lastSceneThumbnail = thumbnail
        lastSceneDate = Date()

        updateUI()
        appLog.info("saveScene done")
    }

    private func deleteScene() {
        let fileManager = FileManager.default

        for url in [sceneGltfURL, sceneUsdzURL, scenePlyURL, sceneThumbnailURL] {
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }

        lastScene = nil
        lastSceneThumbnail = nil
        lastSceneDate = nil

        updateUI()
    }
    
    // MARK: - Helpers
        
    private func updateUI() {
        if lastSceneThumbnail == nil {
            showScanButton.layer.borderWidth = 0
            showScanButton.setTitle("no scan yet", for: UIControl.State.normal)
        } else {
            showScanButton.layer.borderWidth = 1
            showScanButton.setTitle(nil, for: UIControl.State.normal)
        }
        
        showScanButton.setImage(lastSceneThumbnail, for: UIControl.State.normal)
    }
}

extension ViewController: ScanningViewControllerDelegate {
    func scanningViewControllerDidCancel(_ controller: ScanningViewController) {
        dismiss(animated: true)
    }
    
    func scanningViewController(_ controller: ScanningViewController, didScan pointCloud: SCPointCloud) {
        // Snapshot the RGBD dump folder for the next export (B-flow: feed Open3D offline)
        lastRGBDDumpURL = controller.lastFrameDumpURL
        appLog.info("didScan: dumpedFrames=\(controller.dumpedFrameCount) flushing=\(controller.dumperIsFlushing) url=\(controller.lastFrameDumpURL?.lastPathComponent ?? "nil")")

        let vc = ScenePreviewViewController(pointCloud: pointCloud, meshTexturing: controller.meshTexturing, landmarks: nil)
        vc.leftButton.addTarget(self, action: #selector(dismissPreviewedScanTapped), for: UIControl.Event.touchUpInside)
        vc.rightButton.addTarget(self, action: #selector(savePreviewedSceneTapped), for: UIControl.Event.touchUpInside)
        vc.leftButton.setTitle("Rescan", for: UIControl.State.normal)
        vc.leftButton.backgroundColor = UIColor(named: "DestructiveAction")

        // R2: Save 在 mesh 處理完前 disabled,顯示處理狀態
        vc.rightButton.setTitle("Mesh 處理中…", for: UIControl.State.normal)
        vc.rightButton.isEnabled = false
        vc.rightButton.alpha = 0.5
        vc.rightButton.backgroundColor = UIColor.systemGray

        // R1+R3: ScenePreviewViewController 內建 meshingProgressView 已處理進度條;
        // 我們只需聽 mesh 完成 callback 來啟用 Save 按鈕。
        vc.onTexturedMeshGenerated = { [weak vc] _ in
            DispatchQueue.main.async {
                guard let btn = vc?.rightButton else { return }
                btn.setTitle("✅ Save", for: UIControl.State.normal)
                btn.isEnabled = true
                btn.alpha = 1.0
                btn.backgroundColor = UIColor(named: "SaveAction")
            }
        }

        scenePreviewVC = vc
        controller.present(vc, animated: false)
    }

}

private extension URL {
    static let documentsURL: URL = {
        guard let documentsDirectory = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, false).first
            else { fatalError("Failed to find the documents directory") }
        
        // Annoyingly, this gives us the directory path with a ~ in it, so we have to expand it
        let tildeExpandedDocumentsDirectory = (documentsDirectory as NSString).expandingTildeInPath
        
        return URL(fileURLWithPath: tildeExpandedDocumentsDirectory)
    }()
}

