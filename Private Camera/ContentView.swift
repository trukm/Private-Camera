import SwiftUI
import AVFoundation
import PhotosUI
import UIKit
import AVKit
import Combine
import MediaPlayer

// MARK: - Main App Entry
@main
struct PrivateCameraApp: App {
    init() {
        // Ensure directories exist on startup
        MediaManager.shared.createDirectories()
    }
    
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}

// MARK: - Models & Data Manager
enum MediaType: String, Codable {
    case photo, video
}

struct MediaItem: Identifiable, Codable, Equatable {
    let id: UUID
    let type: MediaType
    let creationDate: Date
    let fileName: String
    var deletionDate: Date?
    
    var url: URL {
        MediaManager.shared.getURL(for: fileName)
    }
    
    var relativeDate: Date {
        Calendar.current.startOfDay(for: creationDate)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, type, creationDate, fileName, deletionDate
    }
    
    init(id: UUID, type: MediaType, creationDate: Date, fileName: String, deletionDate: Date? = nil) {
        self.id = id
        self.type = type
        self.creationDate = creationDate
        self.fileName = fileName
        self.deletionDate = deletionDate
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(MediaType.self, forKey: .type)
        creationDate = try container.decode(Date.self, forKey: .creationDate)
        fileName = try container.decode(String.self, forKey: .fileName)
        deletionDate = try container.decodeIfPresent(Date.self, forKey: .deletionDate)
    }
}

class MediaManager: ObservableObject {
    static let shared = MediaManager()
    @Published var items: [MediaItem] = []
    
    private let fileManager = FileManager.default
    private let metaDataKey = "private_camera_metadata"
    
    init() {
        loadMetadata()
    }
    
    func createDirectories() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if !fileManager.fileExists(atPath: docs.path) {
            try? fileManager.createDirectory(at: docs, withIntermediateDirectories: true)
        }
    }
    
    func getURL(for fileName: String) -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
    }
    
    func saveMedia(data: Data, type: MediaType) {
        let id = UUID()
        let ext = type == .photo ? "jpg" : "mp4"
        let fileName = "\(id.uuidString).\(ext)"
        let url = getURL(for: fileName)
        
        do {
            try data.write(to: url)
            let newItem = MediaItem(id: id, type: type, creationDate: Date(), fileName: fileName)
            DispatchQueue.main.async {
                self.items.insert(newItem, at: 0)
                self.saveMetadata()
            }
        } catch {
            print("Error saving media file: \(error)")
        }
    }
    
    func copyMedia(from sourceURL: URL, type: MediaType, move: Bool = false) {
        let id = UUID()
        let ext = type == .photo ? "jpg" : "mp4"
        let fileName = "\(id.uuidString).\(ext)"
        let destURL = getURL(for: fileName)
        
        do {
            if move {
                try fileManager.moveItem(at: sourceURL, to: destURL)
            } else {
                try fileManager.copyItem(at: sourceURL, to: destURL)
            }
            let newItem = MediaItem(id: id, type: type, creationDate: Date(), fileName: fileName)
            DispatchQueue.main.async {
                self.items.insert(newItem, at: 0)
                self.saveMetadata()
            }
        } catch {
            print("Error moving/copying media file: \(error)")
        }
    }
    
    func moveItemToTrash(_ item: MediaItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].deletionDate = Date()
            saveMetadata()
        }
    }
    
    func recoverItem(_ item: MediaItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].deletionDate = nil
            saveMetadata()
        }
    }
    
    func delete(item: MediaItem) {
        try? fileManager.removeItem(at: item.url)
        DispatchQueue.main.async {
            self.items.removeAll { $0.id == item.id }
            self.saveMetadata()
        }
    }
    
    func emptyTrash() {
        DispatchQueue.global(qos: .userInitiated).async {
            let itemsToDelete = self.items.filter { $0.deletionDate != nil }
            for item in itemsToDelete {
                try? self.fileManager.removeItem(at: item.url)
            }
            DispatchQueue.main.async {
                self.items.removeAll { $0.deletionDate != nil }
                self.saveMetadata()
            }
        }
    }
    
    func deleteAllData() {
        DispatchQueue.global(qos: .userInitiated).async {
            for item in self.items {
                try? self.fileManager.removeItem(at: item.url)
            }
            DispatchQueue.main.async {
                self.items.removeAll()
                self.saveMetadata()
            }
        }
    }
    
    func export(item: MediaItem) {
        ExportHelper.shared.export(url: item.url, type: item.type)
    }
    
    func deleteSystemAssets(identifiers: [String]) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        }
    }
    
    private func saveMetadata() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: metaDataKey)
        }
    }
    
    private func loadMetadata() {
        if let data = UserDefaults.standard.data(forKey: metaDataKey),
           let decoded = JSONDecoder().decode([MediaItem].self, associations: data) {
            self.items = decoded.sorted { $0.creationDate > $1.creationDate }
        }
    }
}

// MARK: - Export Utilities
class ExportHelper: NSObject {
    static let shared = ExportHelper()
    
    func export(url: URL, type: MediaType) {
        presentShareSheet(for: [url], showSaveConfirmation: true)
    }
    
    func exportAllToZip(items: [MediaItem]) {
        guard !items.isEmpty else { return }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent("Export_\(UUID().uuidString)")
            
            do {
                try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                for item in items {
                    let dest = tempDir.appendingPathComponent(item.fileName)
                    try? fileManager.copyItem(at: item.url, to: dest)
                }
                
                let coordinator = NSFileCoordinator()
                var error: NSError?
                coordinator.coordinate(readingItemAt: tempDir, options: [.forUploading], error: &error) { zipURL in
                    do {
                        let finalZipURL = fileManager.temporaryDirectory.appendingPathComponent("PrivateCamera_Export.zip")
                        if fileManager.fileExists(atPath: finalZipURL.path) {
                            try fileManager.removeItem(at: finalZipURL)
                        }
                        try fileManager.copyItem(at: zipURL, to: finalZipURL)
                        
                        DispatchQueue.main.async {
                            self.presentShareSheet(for: [finalZipURL], showSaveConfirmation: false)
                        }
                    } catch {
                        print("Error moving zip: \(error)")
                    }
                }
            } catch {
                print("Error creating temp dir: \(error)")
            }
        }
    }
    
    private func presentShareSheet(for items: [Any], showSaveConfirmation: Bool) {
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        
        if showSaveConfirmation {
            activityVC.completionWithItemsHandler = { activityType, completed, returnedItems, error in
                if completed, activityType == .saveToCameraRoll {
                    DispatchQueue.main.async {
                        self.showSaveConfirmationAlert()
                    }
                }
            }
        }
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: \.isKeyWindow),
              let rootVC = window.rootViewController else {
            return
        }
        
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        
        topVC.present(activityVC, animated: true)
    }
    
    private func showSaveConfirmationAlert() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: \.isKeyWindow),
              let rootVC = window.rootViewController else {
            return
        }
        
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        let alert = UIAlertController(title: "Saved", message: "Media has been saved to your Photo Library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topVC.present(alert, animated: true)
    }
}

// Help JSONDecoder map array accurately
extension JSONDecoder {
    func decode<T: Decodable>(_ type: T.Type, associations data: Data) -> T? {
        return try? self.decode(type, from: data)
    }
}

// MARK: - Root View Container
struct MainView: View {
    @State private var selectedTab = 0
    @AppStorage("themeColor") private var themeColor: String = "Red"
    
    var activeColor: Color {
        switch themeColor {
        case "Blue": return .blue
        case "Green": return .green
        default: return .red
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            CameraTabContainer()
                .tabItem {
                    Label("Camera", systemImage: "camera.fill")
                }
                .tag(0)
            
            GalleryView()
                .tabItem {
                    Label("Gallery", systemImage: "photo.stack.fill")
                }
                .tag(1)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(2)
        }
        .accentColor(activeColor)
    }
}

// MARK: - Camera View Implementation
struct CameraTabContainer: View {
    @State private var cameraMode: String = "PHOTO"
    let modes = ["PHOTO", "VIDEO"]
    @StateObject private var cameraEngine = CameraEngine()
    @State private var isPickerPresented = false
    @State private var identifiersToDelete: [String] = []
    @State private var showDeletePrompt = false
    @StateObject private var volumeObserver = VolumeObserver()
    
    var body: some View {
        ZStack {
            HiddenVolumeView()
                .frame(width: 0, height: 0)
            
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack {
                // Top Utilities Bar
                HStack {
                    Button(action: { isPickerPresented = true }) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Text("Private Hub")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { cameraEngine.switchCamera() }) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                }
                .padding()
                
                // View Finder Viewport
                ZStack {
                    CameraPreviewRepresentable(session: cameraEngine.session)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .onAppear {
                            cameraEngine.checkPermissions()
                            volumeObserver.onVolumeButtonPress = {
                                if cameraMode == "VIDEO" {
                                    cameraEngine.toggleVideoRecording()
                                } else {
                                    cameraEngine.capturePhoto()
                                }
                            }
                            volumeObserver.startObserving()
                        }
                        .onDisappear {
                            volumeObserver.stopObserving()
                        }
                    
                    if cameraEngine.isRecording {
                        VStack {
                            HStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 12, height: 12)
                                Text("REC")
                                    .foregroundColor(.white)
                                    .font(.caption)
                                    .bold()
                            }
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                            Spacer()
                        }
                        .padding()
                    }
                    
                    // Zoom Controls Overlay
                    VStack {
                        Spacer()
                        HStack(spacing: 15) {
                            ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { zoom in
                                Button(action: {
                                    cameraEngine.setZoom(zoom)
                                }) {
                                    Text(zoom == 0.5 ? "0.5x" : "\(Int(zoom))x")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(cameraEngine.currentZoom == zoom ? .yellow : .white)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(Color.black.opacity(0.5)))
                                }
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
                
                // Camera Mode Picker Slider
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(modes, id: \.self) { mode in
                            Text(mode)
                                .font(.footnote)
                                .bold()
                                .foregroundColor(cameraMode == mode ? .yellow : .gray)
                                .onTapGesture {
                                    cameraMode = mode
                                }
                        }
                    }
                    .padding(.horizontal, windowWidth / 2 - 30)
                }
                .frame(height: 40)
                
                // Control Capture Layout
                HStack {
                    Spacer()
                    
                    // Shutter Base Trigger Button
                    Button(action: {
                        if cameraMode == "VIDEO" {
                            cameraEngine.toggleVideoRecording()
                        } else {
                            cameraEngine.capturePhoto()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 76, height: 76)
                            Circle()
                                .stroke(Color.black, lineWidth: 2)
                                .frame(width: 68, height: 68)
                            if cameraMode == "VIDEO" {
                                RoundedRectangle(cornerRadius: cameraEngine.isRecording ? 4 : 30)
                                    .fill(Color.red)
                                    .frame(width: cameraEngine.isRecording ? 24 : 60, height: cameraEngine.isRecording ? 24 : 60)
                                    .animation(.easeInOut, value: cameraEngine.isRecording)
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $isPickerPresented) {
            // FIX 1: Pass isPresented binding down so UIKit doesn't force a dismissal
            SystemMediaPicker(isPresented: $isPickerPresented) { identifiers in
                if !identifiers.isEmpty {
                    identifiersToDelete = identifiers
                    // FIX 2: Wait for sheet to finish closing before presenting an alert
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        showDeletePrompt = true
                    }
                }
            }
        }
        .alert("Delete Imported Media?", isPresented: $showDeletePrompt) {
            Button("Delete", role: .destructive) {
                MediaManager.shared.deleteSystemAssets(identifiers: identifiersToDelete)
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Would you like to delete the imported media from your system Photo Library?")
        }
    }
    
    private var windowWidth: CGFloat {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return 390 }
        return windowScene.screen.bounds.width
    }
}

// MARK: - Native iOS Integration Controllers
class VolumeObserver: NSObject, ObservableObject {
    private var observation: NSKeyValueObservation?
    var onVolumeButtonPress: (() -> Void)?
    
    func startObserving() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(true)
        
        observation = audioSession.observe(\.outputVolume, options: [.old, .new]) { [weak self] (_, change) in
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            DispatchQueue.main.async {
                self?.onVolumeButtonPress?()
            }
        }
    }
    
    func stopObserving() {
        observation?.invalidate()
        observation = nil
    }
}

struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

class PreviewView: UIView {
    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreviewRepresentable: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

class CameraEngine: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    @Published var isRecording = false
    @Published var currentZoom: CGFloat = 1.0
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoOutput: AVCaptureMovieFileOutput?
    private var activeInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.setupSession() }
            }
        default: break
        }
    }
    
    private func setupSession() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.beginConfiguration()
            
            // Setup Video Device Input Default
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else { return }
            
            if self.session.canAddInput(videoInput) {
                self.session.addInput(videoInput)
                self.activeInput = videoInput
            }
            
            // Set Audio Input Setup
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               self.session.canAddInput(audioInput) {
                self.session.addInput(audioInput)
            }
            
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            
            let movieOutput = AVCaptureMovieFileOutput()
            if self.session.canAddOutput(movieOutput) {
                self.session.addOutput(movieOutput)
                self.videoOutput = movieOutput
            }
            
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }
    
    func switchCamera() {
        sessionQueue.async {
            guard let currentInput = self.activeInput else { return }
            self.session.beginConfiguration()
            self.session.removeInput(currentInput)
            
            let newPosition: AVCaptureDevice.Position = currentInput.device.position == .back ? .front : .back
            guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                self.session.addInput(currentInput)
                self.session.commitConfiguration()
                return
            }
            
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.activeInput = newInput
                DispatchQueue.main.async {
                    self.currentZoom = 1.0
                }
            } else {
                self.session.addInput(currentInput)
            }
            self.session.commitConfiguration()
        }
    }
    
    func setZoom(_ zoom: CGFloat) {
        sessionQueue.async {
            guard let currentInput = self.activeInput else { return }
            let position = currentInput.device.position
            
            var targetDeviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
            var targetZoom: CGFloat = 1.0
            
            if zoom == 0.5 {
                targetDeviceType = .builtInUltraWideCamera
                targetZoom = 1.0
            } else if zoom == 1.0 {
                targetDeviceType = .builtInWideAngleCamera
                targetZoom = 1.0
            } else if zoom == 2.0 {
                targetDeviceType = .builtInWideAngleCamera
                targetZoom = 2.0
            } else if zoom == 4.0 {
                targetDeviceType = .builtInWideAngleCamera
                targetZoom = 4.0
            }
            
            self.session.beginConfiguration()
            var deviceToUse = currentInput.device
            
            if currentInput.device.deviceType != targetDeviceType {
                if let newDevice = AVCaptureDevice.default(targetDeviceType, for: .video, position: position),
                   let newInput = try? AVCaptureDeviceInput(device: newDevice) {
                    self.session.removeInput(currentInput)
                    if self.session.canAddInput(newInput) {
                        self.session.addInput(newInput)
                        self.activeInput = newInput
                        deviceToUse = newDevice
                    } else {
                        self.session.addInput(currentInput)
                    }
                }
            }
            
            if let _ = try? deviceToUse.lockForConfiguration() {
                deviceToUse.videoZoomFactor = max(deviceToUse.minAvailableVideoZoomFactor, min(targetZoom, deviceToUse.maxAvailableVideoZoomFactor))
                deviceToUse.unlockForConfiguration()
                DispatchQueue.main.async { self.currentZoom = zoom }
            }
            self.session.commitConfiguration()
        }
    }
    
    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func toggleVideoRecording() {
        guard let videoOutput = self.videoOutput else { return }
        if videoOutput.isRecording {
            videoOutput.stopRecording()
            DispatchQueue.main.async {
                self.isRecording = false
            }
        } else {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            videoOutput.startRecording(to: tempURL, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
            }
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation() else { return }
        MediaManager.shared.saveMedia(data: data, type: .photo)
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        MediaManager.shared.copyMedia(from: outputFileURL, type: .video, move: true)
    }
}

// MARK: - Native Import Library Component
struct SystemMediaPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onImportComplete: ([String]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: SystemMediaPicker
        
        init(_ parent: SystemMediaPicker) {
            self.parent = parent
            super.init()
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Let SwiftUI handle the dismissal state safely instead of calling picker.dismiss
            parent.isPresented = false
            
            var identifiers: [String] = []
            let group = DispatchGroup()
            let completion = parent.onImportComplete // Safely copy closure to avoid retention
            
            for result in results {
                if let identifier = result.assetIdentifier {
                    identifiers.append(identifier)
                }
                
                let provider = result.itemProvider
                group.enter()
                
                if provider.canLoadObject(ofClass: UIImage.self) {
                    provider.loadObject(ofClass: UIImage.self) { image, _ in
                        if let uiImage = image as? UIImage, let data = uiImage.jpegData(compressionQuality: 0.85) {
                            MediaManager.shared.saveMedia(data: data, type: .photo)
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                        if let url = url {
                            MediaManager.shared.copyMedia(from: url, type: .video, move: false)
                        }
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                completion(identifiers)
            }
        }
    }
}

// MARK: - In-App Safe Storage Gallery
struct GalleryView: View {
    @ObservedObject var manager = MediaManager.shared
    @State private var targetFullscreenItem: MediaItem?
    @State private var itemToTrash: MediaItem?
    
    var activeItems: [MediaItem] {
        manager.items.filter { $0.deletionDate == nil }
    }
    
    var groupedItems: [Date: [MediaItem]] {
        Dictionary(grouping: activeItems, by: { $0.relativeDate })
    }
    
    var sortedDates: [Date] {
        groupedItems.keys.sorted(by: >)
    }
    
    let columns = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 4)]
    
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(sortedDates, id: \.self) { date in
                        Section(header: Text(date, style: .date).font(.headline).foregroundColor(.gray).textCase(.uppercase).padding(.horizontal)) {
                            LazyVGrid(columns: columns, spacing: 4) {
                                ForEach(groupedItems[date] ?? []) { item in
                                    GalleryThumbnail(item: item)
                                        .onTapGesture { targetFullscreenItem = item }
                                        .contextMenu {
                                            Button { manager.export(item: item) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                            Button(role: .destructive) { itemToTrash = item } label: { Label("Remove Media", systemImage: "trash") }
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(.top)
            }
            .navigationTitle("Secure Vault")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: RecentlyDeletedView()) {
                        Image(systemName: "trash")
                            .foregroundColor(.gray)
                    }
                }
            }
            .fullScreenCover(item: $targetFullscreenItem) { item in
                FullscreenMediaViewer(initialItem: item)
            }
            .alert(item: $itemToTrash) { item in
                Alert(
                    title: Text("Delete Media"),
                    message: Text("Are you sure you want to move this item to Recently Deleted?"),
                    primaryButton: .destructive(Text("Delete")) { manager.moveItemToTrash(item) },
                    secondaryButton: .cancel()
                )
            }
        }
    }
}

struct RecentlyDeletedView: View {
    @ObservedObject var manager = MediaManager.shared
    @State private var itemToActOn: MediaItem?
    @State private var showDeleteAllPrompt = false
    
    var deletedItems: [MediaItem] {
        manager.items.filter { $0.deletionDate != nil }.sorted { $0.creationDate > $1.creationDate }
    }
    
    let columns = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 4)]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(deletedItems) { item in
                    GalleryThumbnail(item: item)
                        .onTapGesture { itemToActOn = item }
                }
            }
            .padding(.top)
            .alert(isPresented: $showDeleteAllPrompt) {
                Alert(
                    title: Text("Delete All"),
                    message: Text("Are you sure you want to permanently delete all items? This action cannot be undone."),
                    primaryButton: .destructive(Text("Delete All")) { manager.emptyTrash() },
                    secondaryButton: .cancel()
                )
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !deletedItems.isEmpty {
                    Button("Delete All") {
                        showDeleteAllPrompt = true
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .alert(item: $itemToActOn) { item in
            Alert(
                title: Text("Recently Deleted"),
                message: Text("What would you like to do with this media?"),
                primaryButton: .default(Text("Recover")) { manager.recoverItem(item) },
                secondaryButton: .destructive(Text("Delete Permanently")) { manager.delete(item: item) }
            )
        }
    }
}

struct GalleryThumbnail: View {
    let item: MediaItem
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if item.type == .photo {
                if let uiImage = UIImage(contentsOfFile: item.url.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 110, maxHeight: 110)
                        .clipped()
                }
            } else {
                VideoThumbnailImage(url: item.url)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 110, maxHeight: 110)
                    .clipped()
            }
            
            if item.type == .video {
                Image(systemName: "video.fill")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(6)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 110, maxHeight: 110)
        .clipped()
        .background(Color.gray.opacity(0.2))
    }
}

struct VideoThumbnailImage: View {
    let url: URL
    @State private var thumbnail: UIImage?
    
    var body: some View {
        Group {
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray
                    .onAppear { generateThumbnail() }
            }
        }
    }
    
    private func generateThumbnail() {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        
        // FIX 3: Retain the generator safely and use the older, stable async API
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cgImage, _, _, _ in
            if let cgImage = cgImage {
                let uiImage = UIImage(cgImage: cgImage)
                DispatchQueue.main.async { self.thumbnail = uiImage }
            }
        }
    }
}

// MARK: - Fullscreen Presentation View Layer
struct FullscreenMediaViewer: View {
    let initialItem: MediaItem
    @ObservedObject var manager = MediaManager.shared
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedItemId: UUID?
    @State private var itemToTrash: MediaItem?
    
    var activeItems: [MediaItem] {
        manager.items.filter { $0.deletionDate == nil }.sorted { $0.creationDate > $1.creationDate }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                TabView(selection: $selectedItemId) {
                    ForEach(activeItems) { item in
                        MediaViewerItem(item: item)
                            .tag(item.id as UUID?)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if selectedItemId == nil {
                    selectedItemId = initialItem.id
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 40) {
                        if let currentMedia = activeItems.first(where: { $0.id == selectedItemId }) {
                            Button(action: { MediaManager.shared.export(item: currentMedia) }) { Image(systemName: "square.and.arrow.up") }
                            Button(action: { itemToTrash = currentMedia }) { Image(systemName: "trash").foregroundColor(.red) }
                        }
                    }
                }
            }
            .alert(item: $itemToTrash) { item in
                Alert(
                    title: Text("Delete Media"),
                    message: Text("Are you sure you want to move this item to Recently Deleted?"),
                    primaryButton: .destructive(Text("Delete")) {
                        manager.moveItemToTrash(item)
                        if activeItems.isEmpty { presentationMode.wrappedValue.dismiss() }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }
}

struct MediaViewerItem: View {
    let item: MediaItem
    var body: some View {
        if item.type == .photo {
            if let uiImage = UIImage(contentsOfFile: item.url.path) {
                ZoomablePhotoView(image: uiImage)
                    .edgesIgnoringSafeArea(.all)
            }
        } else {
            VideoFullscreenPlayer(url: item.url)
                .edgesIgnoringSafeArea(.all)
        }
    }
}

struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5.0
        scrollView.minimumZoomScale = 1.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }
    }
}

struct VideoFullscreenPlayer: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        controller.player = player
        controller.showsPlaybackControls = true
        player.play()
        return controller
    }
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player?.pause()
        uiViewController.player = nil
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @AppStorage("themeColor") private var themeColor: String = "Red"
    @State private var showFirstDeleteConfirmation = false
    @State private var showSecondDeleteConfirmation = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Security")) {
                    NavigationLink(destination: FaceIDGuideView()) {
                        Label("Face ID Setup", systemImage: "faceid")
                    }
                }
                
                Section(header: Text("Appearance")) {
                    Picker("Theme Color", selection: $themeColor) {
                        Text("Red").tag("Red")
                        Text("Blue").tag("Blue")
                        Text("Green").tag("Green")
                    }
                    
                    Button(action: {
                        // Placeholder for app icon change
                        print("App icon change requested")
                    }) {
                        Label("Change App Icon", systemImage: "app.badge")
                    }
                }
                
                Section(header: Text("Data Management")) {
                    Button(action: {
                        ExportHelper.shared.exportAllToZip(items: MediaManager.shared.items)
                    }) {
                        Label("Export All Data (ZIP)", systemImage: "doc.zipper")
                    }
                    
                    Button(action: {
                        showFirstDeleteConfirmation = true
                    }) {
                        Label("Delete All Data", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                    .alert(isPresented: $showFirstDeleteConfirmation) {
                        Alert(
                            title: Text("Delete All Data"),
                            message: Text("Are you sure you want to delete ALL data? This includes everything in your vault and recently deleted items."),
                            primaryButton: .destructive(Text("Proceed")) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    showSecondDeleteConfirmation = true
                                }
                            },
                            secondaryButton: .cancel()
                        )
                    }
                    .background(
                        EmptyView()
                            .alert(isPresented: $showSecondDeleteConfirmation) {
                                Alert(
                                    title: Text("Confirm Deletion"),
                                    message: Text("Are you absolutely sure? This action is permanent and cannot be undone."),
                                    primaryButton: .destructive(Text("Delete Permanently")) {
                                        MediaManager.shared.deleteAllData()
                                    },
                                    secondaryButton: .cancel()
                                )
                            }
                    )
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct FaceIDGuideView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "faceid")
                    .font(.system(size: 70))
                    .foregroundColor(.red)
                    .padding(.top, 40)
                
                Text("Lock App with Face ID")
                    .font(.title2)
                    .bold()
                
                Text("iOS 18+ supports biometric verification directly natively from the Apple Home Screen workspace ecosystem.")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                
                Divider()
                
                VStack(alignment: .leading, spacing: 16) {
                    InstructionRow(step: "1", text: "Go to your iPhone Home Screen.")
                    InstructionRow(step: "2", text: "Press and hold down on the Private Camera app icon.")
                    InstructionRow(step: "3", text: "Select Require Face ID from the contextual popup action engine.")
                    InstructionRow(step: "4", text: "Confirm and authenticate choice configuration setup safely.")
                }
                .padding(.horizontal)
                
                Spacer()
            }
        }
    }
}

struct InstructionRow: View {
    let step: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.red))
            
            Text(text)
                .font(.body)
                .foregroundColor(.primary)
                .padding(.top, 2)
        }
    }
}
