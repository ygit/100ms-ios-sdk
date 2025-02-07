//
//  MeetingViewModel.swift
//  HMSVideo_Example
//
//  Created by Yogesh Singh on 26/02/21.
//  Copyright © 2021 100ms. All rights reserved.
//

import UIKit
import HMSSDK

final class MeetingViewModel: NSObject,
                              UICollectionViewDelegate,
                              UICollectionViewDelegateFlowLayout {

    // MARK: - Properties
    
    var mode: ViewModes = .regular {
        didSet {
            switch mode {
            case .audioOnly:
                switchVideo(isOn: false)
                fallthrough
            case .speakers, .spotlight, .hero:
                dataSource.sortComparator = speakersSort(_:_:)
            case .videoOnly:
                dataSource.sortComparator = videoOnlySort(_:_:)
            case .regular, .pinned:
                dataSource.sortComparator = regularSort(_:_:)
            }
            if oldValue == .speakers {
                dataSource.allModels.forEach { model in
                    applyQuietBorder(model)
                }
            }
            if mode == .hero {
                if let layout = self.collectionView?.collectionViewLayout as? UICollectionViewFlowLayout {
                    layout.scrollDirection = .vertical
                }
            } else if oldValue == .hero {
                if let layout = self.collectionView?.collectionViewLayout as? UICollectionViewFlowLayout {
                    layout.scrollDirection = .horizontal
                }
            }
            dataSource.reload()
            collectionView?.reloadData()
            collectionView?.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
        }
    }

    var onMoreButtonTap: ((HMSRemotePeer, UIButton) -> Void)?
    
    internal var updateLocalPeerTracks: (() -> Void)?
    
    private(set) var interactor: HMSSDKInteractor?

    private weak var collectionView: UICollectionView?

    private lazy var dataSource = {
        HMSDataSource()
    }()

    typealias DiffableDataSource = UICollectionViewDiffableDataSource<HMSSection, HMSViewModel>
    typealias Snapshot = NSDiffableDataSourceSnapshot<HMSSection, HMSViewModel>

    private lazy var diffableDataSource = makeDataSource()

    // MARK: Peers Data Source

    private var pinnedTiles = Set<String>()

    internal var speakers = [HMSViewModel]() {
        didSet {

            if mode == .speakers || mode == .audioOnly || mode == .spotlight || mode == .hero {
                dataSource.reload()
            }
            
            for speaker in oldValue {
                applyQuietBorder(speaker)
            }
            
            for speaker in speakers {
                applySpeakingBorder(speaker)
            }
            
            NotificationCenter.default.post(name: Constants.updatedSpeaker,
                                            object: nil,
                                            userInfo: ["speakers": speakers])
        }
    }
    
    private var shouldPlayAudio = true
    

    // MARK: - Initializers

    init(_ user: String, _ room: String, _ collectionView: UICollectionView, interactor: HMSSDKInteractor) {

        super.init()

        self.interactor = interactor
        setupDataSource()
        interactor.join()

        setup(collectionView)
        
        addObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setup(_ collectionView: UICollectionView) {
        collectionView.delegate = self
        self.collectionView = collectionView
    }

    private func setupDataSource() {
        dataSource.delegate = self
        interactor?.hmsSDK?.add(delegate: dataSource)
        dataSource.sortComparator = regularSort(_:_:)
    }

    private func regularSort(_ lhs: HMSViewModel, _ rhs: HMSViewModel) -> Bool {

        let lhsTrackSource = lhs.videoTrack?.source.rawValue ?? 0
        let rhsTrackSource = rhs.videoTrack?.source.rawValue ?? 0
        
        let lhsAuxTracks = lhs.peer.auxiliaryTracks?.count ?? 0
        let rhsAuxTracks = rhs.peer.auxiliaryTracks?.count ?? 0
        
        if lhsTrackSource != rhsTrackSource {
            return lhsTrackSource > rhsTrackSource
        } else if isPinned(lhs) != isPinned(rhs) {
            return isPinned(lhs) && !isPinned(rhs)
        } else if lhsAuxTracks != rhsAuxTracks {
            return lhsAuxTracks > rhsAuxTracks
        } else if dataSource.allModels.count > 4 {
            return lhs.peer.name.lowercased() < rhs.peer.name.lowercased()
        } else {
            return !lhs.peer.isLocal && rhs.peer.isLocal
        }
    }

    private func videoOnlySort(_ lhs: HMSViewModel, _ rhs: HMSViewModel) -> Bool {
        if let lhsVideo = lhs.videoTrack, let rhsVideo = rhs.videoTrack {
            return !lhsVideo.isMute() && rhsVideo.isMute()
        } else {
            return lhs.videoTrack != nil
        }
    }

    private func speakersSort(_ lhs: HMSViewModel, _ rhs: HMSViewModel) -> Bool {

        let lhsTrackSource = lhs.videoTrack?.source.rawValue ?? 0
        let rhsTrackSource = rhs.videoTrack?.source.rawValue ?? 0
        
        let lhsAuxTracks = lhs.peer.auxiliaryTracks?.count ?? 0
        let rhsAuxTracks = rhs.peer.auxiliaryTracks?.count ?? 0
        
        if lhsTrackSource != rhsTrackSource {
            return lhsTrackSource > rhsTrackSource
        } else if lhsAuxTracks != rhsAuxTracks {
            return lhsAuxTracks > rhsAuxTracks
        }
        
        if speakers.contains(lhs) {
            var count = 4
            if mode == .audioOnly {
                count = 6
            } else if mode == .spotlight {
                count = 1
            }
            
            if let lhsIndex = diffableDataSource?.indexPath(for: lhs)?.item, lhsIndex < count {
                return false
            }
            return true
        }

        return false
    }

    // MARK: - View Modifiers

    private func makeDataSource() -> DiffableDataSource? {

        guard let collectionView = collectionView else { return nil }

        return DiffableDataSource(collectionView: collectionView) { [weak self] (view, index, model) -> UICollectionViewCell? in

            guard let cell = view.dequeueReusableCell(withReuseIdentifier: "Cell",
                                                      for: index) as? VideoCollectionViewCell else {
                return nil
            }

            self?.update(cell, for: model)

            return cell
        }
    }

    private func applySnapshot(animatingDifferences: Bool = true) {
        guard let diffableDataSource = diffableDataSource else { return }

        let sections = dataSource.sections

        var snapshot = Snapshot()

        snapshot.appendSections(sections)

        sections.forEach { section in
            snapshot.appendItems(section.models, toSection: section)
        }

        diffableDataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func update(_ cell: VideoCollectionViewCell, for viewModel: HMSViewModel) {

        cell.viewModel = viewModel

        cell.nameLabel.text = viewModel.peer.name

        cell.muteButton.isSelected = viewModel.peer.audioTrack?.isMute() ?? true

        cell.avatarLabel.text = Utilities.getAvatarName(from: viewModel.peer.name)

        //        cell.pinButton.isSelected = isPinned(viewModel)
        //        cell.onPinToggle = { [weak self] in
        //            self?.togglePinned(viewModel)
        //        }
        
        cell.videoView.videoContentMode = .scaleAspectFill
        
        if let remotePeer = viewModel.peer as? HMSRemotePeer {
            cell.onMoreButtonTap = { [weak self] button in
                self?.onMoreButtonTap?(remotePeer, button)
            }
            
            if viewModel.videoTrack?.source == .screen || viewModel.videoTrack?.source == .plugin {
                cell.moreButton.isHidden = true
                cell.videoView.videoContentMode = .scaleAspectFit
            } else {
                cell.moreButton.isHidden = false
            }
        } else {
            cell.onMoreButtonTap = nil
            cell.moreButton.isHidden = true
        }
        
        
        switch mode {
        case .audioOnly:
            cell.videoView.setVideoTrack(nil)
            cell.stopVideoButton.isSelected = true
            cell.avatarLabel.isHidden = false
        default:
            cell.videoView.isHidden = viewModel.videoTrack?.isDegraded() ?? false
            cell.videoView.setVideoTrack(viewModel.videoTrack)
            if let video = viewModel.videoTrack {
                cell.stopVideoButton.isSelected = video.isMute()
                cell.avatarLabel.isHidden = !video.isMute()
            } else {
                cell.stopVideoButton.isSelected = true
                cell.avatarLabel.isHidden = false
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {

        if mode == .spotlight {
            return .init(width: collectionView.frame.size.width,
                         height: collectionView.frame.size.height)
        } else if mode == .hero {
            if indexPath.item == 0 {
                return .init(width: collectionView.frame.size.width,
                             height: collectionView.frame.size.height * 0.75)
            } else {
                return .init(width: collectionView.frame.size.width * 0.33,
                             height: collectionView.frame.size.height * 0.25)
            }
        }
        
        if let size = sizeFor(indexPath: indexPath, collectionView) {
            return size
        }

        if let count = diffableDataSource?.collectionView(collectionView, numberOfItemsInSection: indexPath.section) {

            switch count {
            case 0, 1:
                return .init(width: collectionView.frame.size.width,
                             height: collectionView.frame.size.height)
            case 2:
                return .init(width: collectionView.frame.size.width,
                             height: collectionView.frame.size.height/2)
            case 3:
                return .init(width: collectionView.frame.size.width,
                             height: collectionView.frame.size.height/3)
            default:
                if mode == .audioOnly && count > 5 {
                    return .init(width: collectionView.frame.size.width/2,
                                 height: collectionView.frame.size.height/3)
                } else {
                    return .init(width: collectionView.frame.size.width/2,
                                 height: collectionView.frame.size.height/2.0)
                }
            }
        }

        return .zero
    }
    
    private func sizeFor(indexPath: IndexPath, _ collectionView: UICollectionView) -> CGSize? {
        let isLandscape = UIDevice.current.orientation == .landscapeRight || UIDevice.current.orientation == .landscapeLeft
        
        if mode == .pinned || mode == .regular || mode == .videoOnly || isLandscape,
           let viewModel = diffableDataSource?.itemIdentifier(for: indexPath) {
            if isPinned(viewModel) ||
                viewModel.videoTrack?.source == .screen ||
                viewModel.videoTrack?.source == .plugin ||
                mode == .pinned ||
                isLandscape {
                return .init(width: collectionView.frame.size.width,
                             height: collectionView.frame.size.height)
            }
        }
        return nil
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {

        guard let videoCell = cell as? VideoCollectionViewCell,
              let model = diffableDataSource?.itemIdentifier(for: indexPath)
        else { return }

        if mode == .audioOnly {
            videoCell.videoView.setVideoTrack(nil)
        } else {
            videoCell.videoView.setVideoTrack(model.videoTrack)
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {

        guard let videoCell = cell as? VideoCollectionViewCell else { return }

        videoCell.videoView.setVideoTrack(nil)
    }

    // MARK: - View Helpers

    private func cellFor(_ model: HMSViewModel) -> VideoCollectionViewCell? {
        guard  let collectionView = collectionView, let index = diffableDataSource?.indexPath(for: model) else { return nil }

        for cell in collectionView.visibleCells where collectionView.indexPath(for: cell) == index {
            if let videoCell = cell as? VideoCollectionViewCell {
                return videoCell
            }
        }
        return nil
    }
    
    private func applySpeakingBorder(_ model: HMSViewModel) {
        guard let cell = cellFor(model) else { return }
        Utilities.applySpeakingBorder(on: cell)
    }
    
    private func applyQuietBorder(_ model: HMSViewModel?) {
        guard let model = model, let cell = cellFor(model) else { return }
        Utilities.applyBorder(on: cell)
    }
    
    private func addObservers() {
     
        _ = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                   object: nil,
                                                   queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.collectionView?.reloadData()
            }
        }
        _ = NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                                   object: nil,
                                                   queue: .main) { [weak self] _ in
            self?.cleanup()
        }
    }

    // MARK: - Action Handlers

    func cleanup() {
        dataSource.delegate = nil
        dataSource.sortComparator = nil
        interactor?.hmsSDK?.leave()
        interactor?.hmsSDK = nil
        interactor = nil
    }

    private func togglePinned(_ model: HMSViewModel) {
        if !pinnedTiles.insert(model.identifier).inserted {
            pinnedTiles.remove(model.identifier)
        }
        dataSource.reload()
    }

    private func isPinned(_ model: HMSViewModel) -> Bool {
        pinnedTiles.contains(model.identifier)
    }

    func switchCamera() {
        if let track = interactor?.hmsSDK?.localPeer?.videoTrack as? HMSLocalVideoTrack {
            track.switchCamera()
        }
    }

    func switchAudio(isOn: Bool) {
        if let peer = interactor?.hmsSDK?.localPeer, let audioTrack = peer.audioTrack as? HMSLocalAudioTrack {
            audioTrack.setMute(!isOn)
            NotificationCenter.default.post(name: Constants.toggleAudioTapped, object: nil, userInfo: ["peer": peer])
        }
    }

    func switchVideo(isOn: Bool) {
        guard let videoTrack = interactor?.hmsSDK?.localPeer?.videoTrack as? HMSLocalVideoTrack else {
            return
        }
        videoTrack.setMute(!isOn)
        NotificationCenter.default.post(name: Constants.toggleVideoTapped,
                                        object: nil,
                                        userInfo: ["video": videoTrack])
    }

    func muteRemoteStreams(_ isMuted: Bool) {

        shouldPlayAudio = isMuted
        
        setMuteStatus(nil)

        NotificationCenter.default.post(name: Constants.muteALL, object: nil)
    }

    func setMuteStatus(_ model: HMSViewModel?) {
        
        let models: [HMSViewModel]
        if let model = model {
            models = [model]
        } else {
            models = dataSource.allModels
        }
        
        for model in models {
            if let peer = model.peer as? HMSRemotePeer {
                if let audio = peer.remoteAudioTrack(),
                   audio.isPlaybackAllowed() != shouldPlayAudio {
                    audio.setPlaybackAllowed(shouldPlayAudio)
                }
                if let auxTracks = model.peer.auxiliaryTracks {
                    for track in auxTracks {
                        if let audio = track as? HMSRemoteAudioTrack {
                            audio.setPlaybackAllowed(shouldPlayAudio)
                        }
                    }
                }
            }
        }
    }
}

extension MeetingViewModel: HMSDataSourceDelegate {

    func didUpdate(_ model: HMSViewModel?) {
        if let model = model, let cell = cellFor(model) {
            update(cell, for: model)
        }
        
        if model?.peer.isLocal == true || model == nil {
            updateLocalPeerTracks?()
        }
        
        setMuteStatus(model)
        applySnapshot()
    }

    func didUpdate(_ speakers: [HMSViewModel]) {
        self.speakers = speakers
    }
}

enum ViewModes: String {
    case regular, audioOnly, videoOnly, speakers, pinned, spotlight, hero
}
