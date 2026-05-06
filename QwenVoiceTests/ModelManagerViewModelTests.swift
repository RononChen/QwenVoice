import XCTest
@testable import QwenVoice

final class ModelManagerViewModelTests: XCTestCase {
    @MainActor
    func testInitMarksCompleteModelDirectoryAsDownloaded() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let installedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createInstalledModelFixture(for: installedModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        guard case .downloaded = viewModel.statuses[installedModel.id] else {
            return XCTFail("Expected \(installedModel.id) to be marked downloaded at init, got \(String(describing: viewModel.statuses[installedModel.id]))")
        }
        let designModel = try XCTUnwrap(TTSModel.model(for: .design))
        let cloneModel = try XCTUnwrap(TTSModel.model(for: .clone))
        XCTAssertEqual(viewModel.statuses[designModel.id], .notDownloaded(message: nil))
        XCTAssertEqual(viewModel.statuses[cloneModel.id], .notDownloaded(message: nil))
    }

    @MainActor
    func testInitMarksPartialModelDirectoryAsRepairable() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let partialModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createPartialModelFixture(for: partialModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        guard case .repairAvailable(_, let missingRequiredPaths, nil) = viewModel.statuses[partialModel.id] else {
            return XCTFail("Expected \(partialModel.id) to be marked repairable, got \(String(describing: viewModel.statuses[partialModel.id]))")
        }
        XCTAssertFalse(missingRequiredPaths.isEmpty)
        XCTAssertTrue(viewModel.isLikelyInstalled(partialModel))
        XCTAssertEqual(viewModel.primaryActionTitle(for: partialModel), "Repair Model")
    }

    @MainActor
    func testRefreshPromotesCompleteModelDirectoryToDownloaded() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let installedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createInstalledModelFixture(for: installedModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        await viewModel.refresh()

        guard case .downloaded = viewModel.statuses[installedModel.id] else {
            return XCTFail("Expected \(installedModel.id) to be marked downloaded after refresh, got \(String(describing: viewModel.statuses[installedModel.id]))")
        }
        let metadataURL = installedModel.installDirectory(in: tempRoot)
            .appendingPathComponent(".qwenvoice-install-metadata.json")
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        XCTAssertEqual(metadata["model_id"] as? String, installedModel.id)
        XCTAssertEqual(metadata["hugging_face_repo"] as? String, installedModel.huggingFaceRepo)
    }

    @MainActor
    func testVariantStatusesAreIndependent() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let speedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        try createInstalledModelFixture(for: speedModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        guard case .downloaded = viewModel.statuses[speedModel.id] else {
            return XCTFail("Expected \(speedModel.id) to be downloaded.")
        }
        XCTAssertEqual(viewModel.statuses[qualityModel.id], .notDownloaded(message: nil))
    }

    @MainActor
    func testUsePersistsActiveVariantSelection() throws {
        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        let key = MacModelVariantPreferences.key(for: .custom)
        let oldValue = UserDefaults.standard.string(forKey: key)
        MacModelVariantPreferences.setSelectedVariantID("speed", for: .custom, defaults: .standard)
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let viewModel = ModelManagerViewModel()
        viewModel.use(qualityModel)

        XCTAssertEqual(
            MacModelVariantPreferences.selectedVariantID(
                for: .custom,
                defaultVariantID: nil
            ),
            "quality"
        )
        XCTAssertTrue(viewModel.isActive(qualityModel))
    }

    /// Audit Finding B coverage — when the user deletes a variant
    /// that is currently Active AND a sibling variant for the
    /// same mode is still installed, the preference must
    /// reassign to the sibling so the Generate flow stays
    /// enabled without an extra Use click.
    @MainActor
    func testDeleteActiveVariantWithInstalledSiblingReassignsPreference() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let speedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        try createInstalledModelFixture(for: speedModel, in: tempRoot)
        try createInstalledModelFixture(for: qualityModel, in: tempRoot)

        let key = MacModelVariantPreferences.key(for: .custom)
        let oldValue = UserDefaults.standard.string(forKey: key)
        MacModelVariantPreferences.setSelectedVariantID("quality", for: .custom, defaults: .standard)
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        XCTAssertTrue(viewModel.isActive(qualityModel), "Pre-condition: Quality is Active.")

        viewModel.delete(qualityModel)

        // Sibling Speed is still installed → preference should
        // reassign to "speed" so Generate stays enabled.
        XCTAssertEqual(
            MacModelVariantPreferences.selectedVariantID(
                for: .custom,
                defaultVariantID: nil
            ),
            "speed",
            "After deleting the Active variant, the preference must reassign to the surviving installed sibling so the Generate button doesn't strand the user."
        )
        XCTAssertTrue(viewModel.isActive(speedModel))
        XCTAssertFalse(viewModel.isActive(qualityModel))
    }

    /// Audit Finding B coverage — when the user deletes their
    /// only-installed variant for a mode, the preference must be
    /// cleared so the hardware-recommended variant becomes
    /// Active again (its row will show as not-yet-installed but
    /// the readiness banner now points the user at a sensible
    /// next step rather than at a deleted folder).
    @MainActor
    func testDeleteActiveVariantWithNoSiblingClearsPreference() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        try createInstalledModelFixture(for: qualityModel, in: tempRoot)

        let key = MacModelVariantPreferences.key(for: .custom)
        let oldValue = UserDefaults.standard.string(forKey: key)
        MacModelVariantPreferences.setSelectedVariantID("quality", for: .custom, defaults: .standard)
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        viewModel.delete(qualityModel)

        XCTAssertNil(
            MacModelVariantPreferences.selectedVariantID(
                for: .custom,
                defaultVariantID: nil
            ),
            "After deleting the only installed variant for a mode, the preference must clear so the hardware-recommended variant takes over."
        )
    }

    /// Audit Finding B regression guard — deleting a NON-active
    /// variant (the user's preference points at the OTHER
    /// variant) must not touch the preference.
    @MainActor
    func testDeleteNonActiveVariantLeavesPreferenceUntouched() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let speedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        try createInstalledModelFixture(for: speedModel, in: tempRoot)
        try createInstalledModelFixture(for: qualityModel, in: tempRoot)

        let key = MacModelVariantPreferences.key(for: .custom)
        let oldValue = UserDefaults.standard.string(forKey: key)
        MacModelVariantPreferences.setSelectedVariantID("quality", for: .custom, defaults: .standard)
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        viewModel.delete(speedModel)  // not the active variant

        XCTAssertEqual(
            MacModelVariantPreferences.selectedVariantID(
                for: .custom,
                defaultVariantID: nil
            ),
            "quality",
            "Deleting a non-active variant must not change the preference."
        )
    }

    private func createInstalledModelFixture(for model: TTSModel, in modelsDirectory: URL) throws {
        let fileManager = FileManager.default
        let modelDirectory = model.installDirectory(in: modelsDirectory)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        for relativePath in model.requiredRelativePaths {
            let fileURL = modelDirectory.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: fileURL)
        }
    }

    /// `sizeText(for:)` is the source of truth for the redesigned
    /// Models tab's size column. Verifies the three live-state
    /// branches: installed (uses on-disk size), repair-available
    /// (also on-disk size), and not-yet-downloaded (uses the
    /// manifest's `estimatedDownloadBytes` and elides the column
    /// when the field is missing).
    @MainActor
    func testSizeTextReadsInstalledSizeBeforeManifestEstimate() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let installed = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        try createInstalledModelFixture(for: installed, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        let installedText = try XCTUnwrap(viewModel.sizeText(for: installed))
        // `createInstalledModelFixture` writes a token file; the
        // exact byte count varies, but `ByteCountFormatter` always
        // emits a unit suffix.
        XCTAssertTrue(
            installedText.hasSuffix("KB") || installedText.hasSuffix("MB") || installedText.hasSuffix("GB") || installedText.hasSuffix("bytes"),
            "Installed size text should carry a unit suffix, got \(installedText)"
        )
    }

    @MainActor
    func testSizeTextReturnsNilWhenNotDownloadedAndManifestHasNoEstimate() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // The current contract manifest sets
        // `estimated_download_bytes: null` for every variant, so a
        // model that's not on disk has no fallback to surface; the
        // UI should elide the size column rather than render an
        // em-dash.
        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        XCTAssertNil(
            viewModel.sizeText(for: qualityModel),
            "When the model is not downloaded and the manifest doesn't carry an estimate, sizeText must return nil."
        )
    }

    private func createPartialModelFixture(for model: TTSModel, in modelsDirectory: URL) throws {
        let fileManager = FileManager.default
        let modelDirectory = model.installDirectory(in: modelsDirectory)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        guard let firstRelativePath = model.requiredRelativePaths.first else {
            XCTFail("Expected requiredRelativePaths for \(model.id)")
            return
        }

        let fileURL = modelDirectory.appendingPathComponent(firstRelativePath)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: fileURL)
    }
}

final class HuggingFaceDownloaderPathValidationTests: XCTestCase {
    func testValidatedRelativeRepoPathRejectsTraversal() {
        XCTAssertThrowsError(try HuggingFaceDownloader.validatedRelativeRepoPath("../model.safetensors")) { error in
            guard case HuggingFaceDownloader.DownloadError.invalidRemotePath(let path) = error else {
                return XCTFail("Expected invalidRemotePath, got \(error)")
            }
            XCTAssertEqual(path, "../model.safetensors")
        }
    }

    func testValidatedRelativeRepoPathRejectsHiddenComponents() {
        XCTAssertThrowsError(try HuggingFaceDownloader.validatedRelativeRepoPath("weights/.secret/model.safetensors")) { error in
            guard case HuggingFaceDownloader.DownloadError.invalidRemotePath(let path) = error else {
                return XCTFail("Expected invalidRemotePath, got \(error)")
            }
            XCTAssertEqual(path, "weights/.secret/model.safetensors")
        }
    }

    func testValidatedDestinationURLAllowsNestedSafePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let destination = try HuggingFaceDownloader.validatedDestinationURL(
            for: "speech_tokenizer/model.safetensors",
            in: root
        )

        XCTAssertTrue(destination.path.hasPrefix(root.path + "/"))
        XCTAssertEqual(destination.lastPathComponent, "model.safetensors")
        XCTAssertEqual(destination.deletingLastPathComponent().lastPathComponent, "speech_tokenizer")
    }
}
