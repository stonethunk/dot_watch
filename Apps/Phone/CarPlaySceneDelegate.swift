import CarPlay
import Combine
import AVFAudio
import DotCore

@MainActor final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CPInterfaceController?
    private var observation: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    private let model = PhoneModel.shared
    private lazy var experience = CarPlayExperience(owner: model)
    private var renderedStatus: String?
    private var pendingStatus: String?
    private var renderID = UUID()

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        experience.connect()
        model.recordCarPlayDisplay(connected: true)
        observation = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.render() }
        }
        render()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await model.load()
            guard !Task.isCancelled else { return }
            render()
        }
        // Connection never starts recording. A visible Talk button starts voice.
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        loadTask?.cancel()
        loadTask = nil
        observation = nil
        controller = nil
        renderedStatus = nil
        pendingStatus = nil
        renderID = UUID()
        experience.disconnect()
        model.recordCarPlayDisplay(connected: false)
    }

    private func render() {
        guard let controller else { return }
        // Ignore amplitude updates: keep driving UI restrained and state-based.
        let key = experience.renderingKey
        guard key != renderedStatus, key != pendingStatus else { return }
        pendingStatus = key
        let id = UUID()
        renderID = id
        controller.setRootTemplate(experience.template(), animated: false) { @Sendable [weak self] success, _ in
            Task { @MainActor in
                guard let self, self.controller != nil, self.renderID == id else { return }
                self.pendingStatus = nil
                if success { self.renderedStatus = key }
                self.model.recordCarPlayDisplay(connected: true, templateAccepted: success)
            }
        }
    }
}
