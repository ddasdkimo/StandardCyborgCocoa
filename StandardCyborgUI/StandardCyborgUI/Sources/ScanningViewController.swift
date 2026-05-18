import AVFoundation
import StandardCyborgFusion
import UIKit

@objc public protocol ScanningViewControllerDelegate: AnyObject {
    func scanningViewControllerDidCancel(_ controller: ScanningViewController)
    @objc optional func scanningViewController(_ controller: ScanningViewController, didScan pointCloud: SCPointCloud)
}

/**
    Shows a live color + depth camera preview and shutter button.
 
    When the shutter is tapped, performs a customizable 3-second
    countdown, then starts scanning.
 
    When scanning is manually finished, or if it fails,
    reconstructs a 3D point cloud and informs its delegate.
 
    This class does not itself show a preview of the scan.
 
    Rendering can be customized by setting the scanningViewRenderer
    to your own object conforming to that protocol.
 */
@objc open class ScanningViewController: UIViewController,
    CameraManagerDelegate,
    SCReconstructionManagerDelegate
{
    
    // MARK: - Public
    
    @objc public enum ScanningTerminationReason: Int {
        case canceled
        case finished
    }
    
    @objc public weak var delegate: ScanningViewControllerDelegate?
    
    /** Override to drop in your own visualization */
    @objc public lazy var scanningViewRenderer: ScanningViewRenderer =
        DefaultScanningViewRenderer(device: _metalDevice, commandQueue: _visualizationCommandQueue)
    
    /** The duration of each count in the pre-scan countdown after tapping the shutter button */
    @objc public var countdownPerSecondDuration = 0.75
    
    /** The count of the pre-scan countdown after tapping the shutter button. Set to 0 to disable the countdown. */
    @objc public var countdownStartCount = 3
    
    /** You may customize the dismiss button by setting its public properties, or by hiding it and adding your own */
    @objc public let dismissButton = UIButton()
    
    /** You may customize the shutter button by setting ShutterButton's public properties, or by hiding it and adding your own */
    @objc public let shutterButton = ShutterButton()
    
    /** A convenience initializer that simply calls init() and sets the delegate */
    @objc public convenience init(delegate: ScanningViewControllerDelegate) {
        self.init()
        self.delegate = delegate
    }
    
    @objc public func shutterTapped(_ sender: UIButton?) {
        guard
            presentedViewController == nil,
            _cameraManager.isSessionRunning
            else { return }
        
        switch _state {
        case .default:
            _startCountdown { self.startScanning() }
        case .countdownSeconds(let seconds):
            if seconds > 0 {
                ScanningHapticFeedbackEngine.shared.scanningCanceled()
                _cancelCountdown()
            }
        case .scanning:
            ScanningHapticFeedbackEngine.shared.scanningFinished()
            stopScanning(reason: .finished)
        }
    }
    
    /** Starts scanning immediately */
    @objc public func startScanning() {
        ScanningHapticFeedbackEngine.shared.scanningBegan()

        _state = .scanning
        _assimilatedFrameIndex = 0
        meshTexturing.reset()

        if dumpsRawFrames {
            do {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let dumper = try RGBDFrameDumper(rootDirectory: docs)
                _frameDumper = dumper
                // Expose session path immediately so the export UI can pick it up even before
                // finalize completes.
                lastFrameDumpURL = dumper.sessionURL
            } catch {
                print("[FrameDumper] failed to start: \(error)")
                _frameDumper = nil
                lastFrameDumpURL = nil
            }
        } else {
            _frameDumper = nil
            lastFrameDumpURL = nil
        }
    }
    
    /** Stops scanning immediately */
    @objc public func stopScanning(reason: ScanningTerminationReason) {
        guard _state == _State.scanning else { return }
        
        _state = .default
        _latestViewMatrix = matrix_identity_float4x4
        _updateUI()
        
        switch reason {
        case .canceled: ScanningHapticFeedbackEngine.shared.scanningCanceled()
        case .finished: ScanningHapticFeedbackEngine.shared.scanningFinished()
        }
        
        if reason == .finished {
            // Finalize the RGBD dump for this pass (single or multi). For multi-pass,
            // we append the session URL to capturedSessionURLs once it lands.
            if let dumper = _frameDumper {
                if multiPassMode {
                    capturedSessionURLs.append(dumper.sessionURL)
                }
                dumper.finalize { [weak self] url, error in
                    DispatchQueue.main.async {
                        self?.lastFrameDumpURL = url
                        if let err = error {
                            print("[FrameDumper] finalize error: \(err)")
                        } else if let url = url {
                            print("[FrameDumper] wrote session: \(url.path) (\(dumper.frameCount) frames)")
                        }
                    }
                }
                _frameDumper = nil
            }

            if multiPassMode {
                // Keep camera + reconstruction manager alive; just reset reconstruction
                // so the next pass fuses cleanly without bleeding the previous pass's
                // accumulated voxels. The SDK mesh per-pass is not used in the P-flow
                // pipeline anyway — only the RGBD dumps matter — so resetting is safe.
                _reconstructionManager.reset()
                meshTexturing.reset()
                _updateUI()
                return
            }

            // Single-pass: finalize SDK mesh and stop the camera as before.
            _cameraManager.stopSession()
            meshTexturing.cameraCalibrationData = _reconstructionManager.latestCameraCalibrationData
            meshTexturing.cameraCalibrationFrameWidth = _reconstructionManager.latestCameraCalibrationFrameWidth
            meshTexturing.cameraCalibrationFrameHeight = _reconstructionManager.latestCameraCalibrationFrameHeight

            // Do final cleanup on the scan
            _reconstructionManager.finalize {
                let pointCloud = self._reconstructionManager.buildPointCloud()
                // Reset it now to keep peak memory usage down
                self._reconstructionManager.reset()
                self.delegate?.scanningViewController?(self, didScan: pointCloud)
            }
        } else {
            _reconstructionManager.reset()
            meshTexturing.reset()
            _frameDumper = nil
        }
    }

    /// Multi-pass: when the user has captured enough passes, call this to wrap up.
    /// Equivalent to a single-pass `stopScanning(.finished)` flow, except the
    /// delegate also has `capturedSessionURLs` populated with every pass's dump.
    @objc public func finishMultiPassScanning() {
        // If a pass is currently in progress, stop it first (its URL gets appended).
        if _state == .scanning {
            stopScanning(reason: .finished)
        }
        _cameraManager.stopSession()
        meshTexturing.cameraCalibrationData = _reconstructionManager.latestCameraCalibrationData
        meshTexturing.cameraCalibrationFrameWidth = _reconstructionManager.latestCameraCalibrationFrameWidth
        meshTexturing.cameraCalibrationFrameHeight = _reconstructionManager.latestCameraCalibrationFrameHeight
        _reconstructionManager.finalize {
            let pointCloud = self._reconstructionManager.buildPointCloud()
            self._reconstructionManager.reset()
            self.delegate?.scanningViewController?(self, didScan: pointCloud)
        }
    }

    @objc private func _endButtonTapped(_ sender: UIButton) {
        finishMultiPassScanning()
    }
    
    @objc public var maxDepthResolution: Int = 320 {
        didSet {
            if isViewLoaded && oldValue != maxDepthResolution {
                _cameraManager.configureCaptureSession(maxResolution: maxDepthResolution)
            }
        }
    }
    
    /** To manually pause the camera output, set this to true */
    @objc public var isCameraPaused: Bool = false {
        didSet {
            guard oldValue != isCameraPaused else { return }
            
            if isCameraPaused {
                _cameraManager.stopSession()
            } else {
                _cameraManager.startSession(nil)
            }
        }
    }
    
    /** If true, displays a button that flips the output horizontally for scanning with a mirror bracket */
    @objc public var showsMirrorModeButton: Bool = false {
        didSet { _updateUI() }
    }
    
    @objc public var mirrorModeEnabled: Bool {
        get { return _mirrorModeButton.isSelected }
        set {
            _mirrorModeButton.isSelected = newValue
            meshTexturing.flipsInputHorizontally = newValue
        }
    }
    
    @objc public var generatesTexturedMeshes: Bool = false {
        didSet { _reconstructionManager.includesColorBuffersInMetadata = generatesTexturedMeshes }
    }
    @objc public var texturedMeshColorBufferSaveInterval: Int = 8

    /// When true (default), scanning stops automatically as soon as the reconstruction
    /// pipeline reports `.failed` for a frame. Set to false to keep scanning until the
    /// user explicitly taps the shutter — useful for sweeping around an object where
    /// transient frame failures are expected (e.g. circling a foot).
    @objc public var automaticallyStopsOnFailure: Bool = true

    /// If true, every accumulated frame is also written to disk as RGB+depth (uint16 mm PNG)
    /// alongside the live fusion pipeline. After scanning stops, `lastFrameDumpURL` points to
    /// the session folder for export. Used by MyFactory's offline Open3D reconstruction path.
    @objc public var dumpsRawFrames: Bool = false

    /// Populated after a `dumpsRawFrames = true` scan finishes. URL of the session folder.
    @objc public private(set) var lastFrameDumpURL: URL?

    /// Multi-pass mode for the MyFactory P-flow: every shutter-driven stop just
    /// finalizes the current RGBD dump and stays in default state, ready for
    /// the user to start another pass. Pressing `endButton` (top-right) calls
    /// the delegate with the last pass's mesh, and passes all session URLs via
    /// `capturedSessionURLs`. Off by default to keep the original single-pass UX.
    @objc public var multiPassMode: Bool = false {
        didSet { _updateUI() }
    }

    /// In multiPassMode, accumulated RGBD dump folders across all completed
    /// passes within this scanner presentation. Read this in the
    /// scanningViewController(_:didScan:) delegate callback.
    @objc public private(set) var capturedSessionURLs: [URL] = []

    /// Top-right "結束 / Finish" button shown only in multiPassMode.
    /// Customize text/style by tweaking these in the host app.
    @objc public let endButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("結束", for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor(red: 0, green: 0.48, blue: 1, alpha: 0.85)
        b.layer.cornerRadius = 16
        b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 18, bottom: 6, right: 18)
        return b
    }()

    /// Diagnostic helpers exposed for the host app to read while debugging.
    @objc public var dumpedFrameCount: Int { _frameDumper?.frameCount ?? 0 }
    @objc public var dumperIsFlushing: Bool { _frameDumper?.isFlushing ?? false }

    @objc public lazy var meshTexturing = SCMeshTexturing()
    
    // MARK: - UIViewController
    open override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
    
        _setUpSubviews()
        
        _cameraManager.delegate = self
        _cameraManager.configureCaptureSession(maxResolution: maxDepthResolution)
        
        _reconstructionManager.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(_thermalStateChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }
    
    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        guard CameraManager.isDepthCameraAvailable else { return }
        
        _startCameraSession()
    }
    
    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        stopScanning(reason: ScanningViewController.ScanningTerminationReason.canceled)
        
        _cameraManager.stopSession()
    }
    
    override open func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        _metalContainerView.frame = view.bounds
        
        CATransaction.begin()
        CATransaction.disableActions()
        _metalLayer.frame = _metalContainerView.bounds
        _metalLayer.drawableSize = CGSize(width:  _metalLayer.frame.width  * _metalLayer.contentsScale,
                                          height: _metalLayer.frame.height * _metalLayer.contentsScale)
        CATransaction.commit()
        
        _countdownLabel.sizeToFit()
        _countdownLabel.center = _metalContainerView.center
        _scanFailedLabel.sizeToFit()
        _scanFailedLabel.center = _metalContainerView.center
        dismissButton.sizeToFit()
        dismissButton.center = CGPoint(x: 20 + 0.5 * dismissButton.frame.width,
                                       y: 0.5 * dismissButton.frame.height + view.safeAreaInsets.top)
        
        _mirrorModeBackground.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: dismissButton.frame.maxY + 15)
        _mirrorModeLabel.sizeToFit()
        _mirrorModeLabel.center = CGPoint(x: view.bounds.midX,
                                          y: dismissButton.center.y)
        _mirrorModeButton.sizeToFit()
        _mirrorModeButton.center = CGPoint(x: view.bounds.maxX - 0.5 * _mirrorModeButton.frame.width - 20,
                                           y: dismissButton.center.y)
        
        shutterButton.sizeToFit()
        shutterButton.center = CGPoint(x: view.bounds.midX,
                                       y: view.bounds.maxY - 5 - 0.5 * shutterButton.frame.size.height - view.safeAreaInsets.bottom)

        endButton.sizeToFit()
        endButton.center = CGPoint(x: view.bounds.maxX - 0.5 * endButton.frame.width - 20,
                                   y: 0.5 * endButton.frame.height + view.safeAreaInsets.top + 4)
    }
    
    override open func didReceiveMemoryWarning() {
        print("Received low memory warning; stopping scanning")
        stopScanning(reason: .finished)
    }
    
    // MARK: - Notifications
    
    @objc private func _focusOnTap(_ gesture: UITapGestureRecognizer) {
        // Disallow this while scanning
        guard _state != _State.scanning else { return }
        
        let location = gesture.location(in: view)
        
        _cameraManager.focusOnTap(at: location)
    }
    
    @objc private func _thermalStateChanged(notification: Notification) {
        guard let processInfo = notification.object as? ProcessInfo,
            processInfo.thermalState == .critical
            else { return }
        
        DispatchQueue.main.async(execute: _stopScanningForCriticalThermalState)
    }
    
    // MARK: - CameraManagerDelegate
    
    public func cameraDidOutput(colorBuffer: CVPixelBuffer, depthBuffer: CVPixelBuffer, depthCalibrationData: AVCameraCalibrationData) {
        var isScanning = false
        DispatchQueue.main.sync {
            isScanning = self._state == _State.scanning
        }

        let pointCloud: SCPointCloud

        if isScanning {
            pointCloud = _reconstructionManager.buildPointCloud()
        } else {
            // When the user is not scanning, render a preview by reconstructing the most recent depth buffer
            // into a point cloud from the current point of view, drawn on top of the RGB camera
            // As the result is never saved and the RGB color not used for visualization, there is no need to
            // pass it the color buffer to build the point cloud
            pointCloud = _reconstructionManager.reconstructSingleDepthBuffer(depthBuffer,
                                                                             colorBuffer: nil,
                                                                             with: depthCalibrationData,
                                                                             smoothingPoints: true)
        }

        scanningViewRenderer.draw(colorBuffer: colorBuffer,
                                  pointCloud: pointCloud,
                                  depthCameraCalibrationData: depthCalibrationData,
                                  viewMatrix: _latestViewMatrix,
                                  into: _metalLayer)

        if isScanning {
            _reconstructionManager.accumulate(depthBuffer: depthBuffer,
                                              colorBuffer: colorBuffer,
                                              calibrationData: depthCalibrationData)

            // Mirror frames to disk for offline Open3D reconstruction (MyFactory B-flow)
            _frameDumper?.dump(colorBuffer: colorBuffer,
                               depthBuffer: depthBuffer,
                               calibration: depthCalibrationData)
        }
    }
    
    // MARK: - SCReconstructionManagerDelegate
    
    public func reconstructionManager(_ manager: SCReconstructionManager, didProcessWith metadata: SCAssimilatedFrameMetadata, statistics: SCReconstructionManagerStatistics) {
        guard _state == .scanning else { return }
        
        _latestViewMatrix = metadata.viewMatrix
        
        switch metadata.result {
        case .succeeded, .poorTracking:
            // Save off every nth frame
            if
                generatesTexturedMeshes
                && _assimilatedFrameIndex % texturedMeshColorBufferSaveInterval == 0,
                let colorBuffer = metadata.colorBuffer?.takeUnretainedValue()
            {
                meshTexturing.saveColorBufferForReconstruction(colorBuffer,
                                                               withViewMatrix: metadata.viewMatrix,
                                                               projectionMatrix: metadata.projectionMatrix)
            }
            _assimilatedFrameIndex += 1
            
        case .failed:
            if automaticallyStopsOnFailure {
                let assimilatedTooFewFrames = statistics.succeededCount < _failedScanShowPreviewMinFrameCount
                stopScanning(reason: assimilatedTooFewFrames ? .canceled : .finished)
            }

        case .lostTracking:
            break
        @unknown default:
            break
        }
    }
    
    public func reconstructionManager(_ manager: SCReconstructionManager, didEncounterAPIError error: Error) {
        print("SCReconstructionManager hit API error: \(error)")
        stopScanning(reason: ScanningViewController.ScanningTerminationReason.canceled)
    }
    
    // MARK: - Private properties
        
    private let _metalDevice = MTLCreateSystemDefaultDevice()!
    private lazy var _algorithmCommandQueue = _metalDevice.makeCommandQueue()!
    private lazy var _visualizationCommandQueue = _metalDevice.makeCommandQueue()!
    private lazy var _reconstructionManager = SCReconstructionManager(device: _metalDevice, commandQueue: _algorithmCommandQueue, maxThreadCount: _maxReconstructionThreadCount)
    private let _cameraManager = CameraManager()
    private var _latestViewMatrix = matrix_identity_float4x4
    private var _assimilatedFrameIndex = 0
    private var _frameDumper: RGBDFrameDumper?
    
    private let _metalContainerView = UIView()
    private let _metalLayer = CAMetalLayer()
    private let _countdownLabel = UILabel()
    private let _scanFailedLabel = UILabel()
    
    private let _mirrorModeBackground = UIView()
    private let _mirrorModeLabel = UILabel()
    private let _mirrorModeButton = UIButton()
    
    // MARK: - UI State Management
    
    private enum _State: Equatable {
        case `default`
        case countdownSeconds(Int)
        case scanning
    }
    
    private var _state = _State.default {
        didSet {
            _updateUI()
            
            // Prevent auto screen dimming/lock while scanning
            UIApplication.shared.isIdleTimerDisabled = _state == _State.scanning
        }
    }
    
    private func _setUpSubviews() {
        view.backgroundColor = UIColor.black
        
        _metalLayer.isOpaque = true
        _metalLayer.contentsScale = UIScreen.main.scale
        _metalLayer.device = _metalDevice
        _metalLayer.pixelFormat = MTLPixelFormat.bgra8Unorm
        _metalLayer.framebufferOnly = false
        
        _metalContainerView.layer.addSublayer(_metalLayer)
        view.addSubview(_metalContainerView)
        view.addSubview(_countdownLabel)
        view.addSubview(_scanFailedLabel)
        view.addSubview(_mirrorModeBackground)
        view.addSubview(dismissButton)
        view.addSubview(shutterButton)
        view.addSubview(endButton)
        endButton.addTarget(self, action: #selector(_endButtonTapped(_:)), for: .touchUpInside)
        _mirrorModeBackground.addSubview(_mirrorModeLabel)
        _mirrorModeBackground.addSubview(_mirrorModeButton)
        
        let mirrorModeText = NSMutableAttributedString(string: "Mirror Mode On\n", attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .bold)])
        mirrorModeText.append(NSAttributedString(string: "Attach Mirror Clip", attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .regular)]))
        
        _mirrorModeBackground.backgroundColor = UIColor(white: 0, alpha: 0.28)
        _mirrorModeLabel.attributedText = mirrorModeText
        _mirrorModeLabel.textColor = UIColor.white
        _mirrorModeLabel.textAlignment = NSTextAlignment.center
        _mirrorModeLabel.numberOfLines = 2
        _mirrorModeButton.addTarget(self, action: #selector(toggleMirrorMode(_:)), for: UIControl.Event.touchUpInside)
        _mirrorModeButton.setImage(UIImage(named: "FlipCamera", in: Bundle.scuiResourcesBundle, compatibleWith: nil)!, for: UIControl.State.normal)
        
        _countdownLabel.textColor = UIColor.white
        _countdownLabel.textAlignment = NSTextAlignment.center
        _countdownLabel.font = UIFont.systemFont(ofSize: 96, weight: UIFont.Weight.semibold)
        
        _scanFailedLabel.text = "Scan failed!\nMove the device slowly\nand keep the subject still"
        _scanFailedLabel.numberOfLines = 0
        _scanFailedLabel.textAlignment = NSTextAlignment.center
        _scanFailedLabel.font = UIFont.systemFont(ofSize: 24, weight: UIFont.Weight.medium)
        _scanFailedLabel.backgroundColor = UIColor(white: 1.0, alpha: 0.8)
        _scanFailedLabel.isHidden = true
        
        dismissButton.setImage(UIImage(named: "Dismiss", in: Bundle.scuiResourcesBundle, compatibleWith: nil), for: UIControl.State.normal)
        dismissButton.addTarget(self, action: #selector(dismissTapped(_:)), for: UIControl.Event.touchUpInside)
        shutterButton.addTarget(self, action: #selector(shutterTapped(_:)), for: UIControl.Event.touchUpInside)
        
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(_focusOnTap)))
    }
    
    private func _updateUI() {
        loadViewIfNeeded()
        
        switch _state {
        case .default:
            shutterButton.shutterButtonState = .default
            
        case .countdownSeconds(let seconds):
            shutterButton.shutterButtonState = .countdown
            _countdownLabel.isHidden = seconds == 0
            _countdownLabel.text = "\(seconds)"
            _countdownLabel.sizeToFit()
            
        case .scanning:
            shutterButton.shutterButtonState = .scanning
            
        }
        
        _cameraManager.isFocusLocked = _state == .scanning
        
        _mirrorModeBackground.isHidden = !showsMirrorModeButton
        _mirrorModeLabel.isHidden = !mirrorModeEnabled
        scanningViewRenderer.flipsInputHorizontally = mirrorModeEnabled
        _reconstructionManager.flipsInputHorizontally = mirrorModeEnabled

        // End button shows only in multi-pass mode, between passes (not while
        // a pass is actively scanning — to prevent accidental taps mid-scan).
        let endVisible = multiPassMode && _state != .scanning && !capturedSessionURLs.isEmpty
        endButton.isHidden = !endVisible
        if endVisible {
            endButton.setTitle("結束 (\(capturedSessionURLs.count) 段)", for: .normal)
        }
    }
    
    private func _startCameraSession() {
        _cameraManager.startSession { result in
            switch result {
            case .success:
                break
            case .configurationFailed:
                print("Configuration failed for an unknown reason")
            case .notAuthorized:
                let message = "To take a 3D scan, go to your privacy settings. Tap Camera and turn on for Capture"
                let alertController = UIAlertController(title: "Camera Access", message: message, preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: "OK",
                                                        style: .cancel,
                                                        handler: nil))
                alertController.addAction(UIAlertAction(title: "Open Settings",
                                                        style: .`default`)
                { _ in
                    UIApplication.shared.open(URL.init(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
                })
                
                self.present(alertController, animated: true)
            }
        }
    }
    
    private func _startCountdown(_ completion: @escaping () -> Void) {
        guard countdownStartCount > 0 else {
            completion()
            return
        }
        
        _state = .countdownSeconds(countdownStartCount)
        _iterateCountdown(completion)
    }
    
    private func _cancelCountdown() {
        ScanningHapticFeedbackEngine.shared.scanningCanceled()
        _countdownLabel.alpha = 0
        _state = .default
    }
    
    private func _iterateCountdown(_ completion: @escaping () -> Void) {
        ScanningHapticFeedbackEngine.shared.countdownCountedDown()
        
        if case let _State.countdownSeconds(seconds) = _state, seconds == 0 {
            completion()
            return
        }
        
        _countdownLabel.alpha = 1
        UIView.animate(withDuration: countdownPerSecondDuration, animations: {
            self._countdownLabel.alpha = 0
        }) { finished in
            if
                finished,
                case let _State.countdownSeconds(seconds) = self._state,
                seconds > 0
            {
                self._state = _State.countdownSeconds(seconds - 1)
                self._iterateCountdown(completion)
            }
        }
    }
    
    private let _failedScanShowPreviewMinFrameCount = 50
    
    private lazy var _maxReconstructionThreadCount: Int32 = {
        // Unfortunately, there's not a good way to get the number of *high-performance*
        // CPU cores on iOS, so we have to hard-code this for now
        return UIDevice.current.userInterfaceIdiom == .pad ? 4 : 2
    }()
    
    private func _showScanFailedMessage() {
        _scanFailedLabel.isHidden = false
        _scanFailedLabel.alpha = 1
        
        UIView.animate(withDuration: 0.8, delay: 3.0, options: [], animations: {
            self._scanFailedLabel.alpha = 0
        }, completion: { finished in
            self._scanFailedLabel.isHidden = true
        })
    }
    
    private func _stopScanningForCriticalThermalState() {
        if _state == _State.scanning {
            self.stopScanning(reason: .finished)
        }
        
        let deviceName = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let alertController = UIAlertController(title: "\(deviceName) is too hot!",
            message: "Please allow \(deviceName) to cool down and try again",
            preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
        self.present(alertController, animated: true)
    }
    
    @objc private func toggleMirrorMode(_ sender: UIButton) {
        sender.isSelected = !sender.isSelected
        _updateUI()
    }
    
    @objc private func dismissTapped(_ sender: UIButton?) {
        delegate?.scanningViewControllerDidCancel(self)
    }
    
}
