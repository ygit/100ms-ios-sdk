//
//  ChatViewController.swift
//  HMSSDKExample
//
//  Created by Yogesh Singh on 28/02/21.
//  Copyright © 2021 100ms. All rights reserved.
//

import UIKit
import HMSSDK

final class ChatViewController: UIViewController {

    internal var interactor: HMSSDKInteractor?

    @IBOutlet private weak var table: UITableView!
    @IBOutlet private weak var stackView: UIStackView!
    @IBOutlet private weak var textField: UITextField!
    @IBOutlet private weak var sendButton: UIButton!
    @IBOutlet weak var receiverButton: UIButton! {
        didSet {
            if #available(iOS 14.0, *) {
                receiverButton.menu = menu
                receiverButton.showsMenuAsPrimaryAction = true
            } else {
                // Fallback on earlier versions
            }
        }
    }
    
    typealias DataSource = UITableViewDiffableDataSource<ChatSection, HMSMessage>
    typealias Snapshot = NSDiffableDataSourceSnapshot<ChatSection, HMSMessage>

    private lazy var dataSource = makeDataSource()
    
    var menu: UIMenu {
        UIMenu(title: "Send Message to", image: nil, identifier: nil, options: [], children: menuItems)
    }
    
    var menuItems: [UIAction] {
        
        var result = [
            UIAction(title: "Everyone",
                     image: UIImage(systemName: "speaker.wave.3")?.withTintColor(.link)) { [weak self] _ in
                self?.selectedRecipient = nil // implies send message to all
                self?.receiverButton.setTitle("Everyone", for: .normal)
            }
        ]
        
        if let roles = interactor?.hmsSDK?.roles {
            roles.forEach { role in
                result.append(UIAction(title: role.name, image: nil) { [weak self] _ in
                    self?.selectedRecipient = role
                    self?.receiverButton.setTitle(role.name, for: .normal)
                })
            }
        }
        
        if let peers = interactor?.hmsSDK?.remotePeers {
            let sortedPeers = peers.sorted { $0.name < $1.name }
            
            sortedPeers.forEach { peer in
                result.append(UIAction(title: peer.name, image: nil) { [weak self] _ in
                    self?.selectedRecipient = peer
                    self?.receiverButton.setTitle(peer.name, for: .normal)
                })
            }
        }
        
        return result
    }
    
    var selectedRecipient: AnyObject?
    

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        table.tableFooterView = UIView()
        table.estimatedRowHeight = 64
        table.rowHeight = UITableView.automaticDimension
        table.tableFooterView = stackView

        observeBroadcast()
        handleKeyboard()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        textField.becomeFirstResponder()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applySnapshot()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View Modifiers

    private func handleKeyboard() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(notification: NSNotification) {

        guard let userInfo = notification.userInfo,
              var keyboardFrame = (userInfo[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue
        else { return }

        keyboardFrame = view.convert(keyboardFrame, from: nil)

        var contentInset = table.contentInset
        contentInset.bottom = keyboardFrame.size.height + 30
        table.contentInset = contentInset
    }

    @objc private func keyboardWillHide(notification: NSNotification) {

        let contentInset = UIEdgeInsets.zero
        table.contentInset = contentInset
    }

    // MARK: - Action Handlers

    private func observeBroadcast() {
        _ = NotificationCenter.default.addObserver(forName: Constants.messageReceived,
                                                   object: nil,
                                                   queue: .main) { [weak self] _ in
            self?.applySnapshot()
            self?.table.scrollToBottom()
        }
    }

    @IBAction private func closeTapped(_ sender: UIButton) {
        dismiss(animated: true)
    }

    @IBAction private func sendTapped(_ sender: UIButton) {
        guard let message = textField.text,
              !message.isEmpty,
              let interactor = interactor
        else { return }

        sender.isEnabled = false
        
        let messageHandler: ((HMSMessage?, HMSError?) -> Void) = { [weak self, weak sender] message, error in
            sender?.isEnabled = true
            
            if let message = message {
                self?.append(message)
            } else if let error = error {
                self?.showMessageSendError(error)
            }
        }

        switch selectedRecipient {
        case is HMSRole:
            interactor.hmsSDK?.sendGroupMessage(message: message, roles: [selectedRecipient as! HMSRole], completion: messageHandler)
        case is HMSPeer:
            interactor.hmsSDK?.sendDirectMessage(message: message, peer: (selectedRecipient as! HMSPeer), completion: messageHandler)
        default:
            interactor.hmsSDK?.sendBroadcastMessage(message: message, completion: messageHandler)
        }
    }
    
    private func showMessageSendError(_ error: HMSError) {
        let title = "Could Not Send a Message"

        let alertController = UIAlertController(title: title,
                                                message: error.message,
                                                preferredStyle: .alert)
        

        alertController.addAction(UIAlertAction(title: "Ok", style: .cancel))

        present(alertController, animated: true)
    }
    
    private func append(_ message: HMSMessage)  {
        interactor?.messages.append(message)
        applySnapshot()
        
        if let index = dataSource?.indexPath(for: message) {
            table.scrollToRow(at: index, at: .top, animated: true)
        }

        textField.text = ""
    }
}

extension ChatViewController {

    func makeDataSource() -> DataSource? {

        let dataSource = DataSource(tableView: table) { (table, indexPath, message) -> UITableViewCell? in

            guard let cell = table.dequeueReusableCell(withIdentifier: "Cell",
                                                       for: indexPath) as? ChatTableViewCell else {
                return nil
            }

            self.update(cell, for: message)

            return cell
        }
        return dataSource
    }

    func update(_ cell: ChatTableViewCell, for message: HMSMessage) {

        var name = message.sender?.name
        var isLocal = false

        if let peer = message.sender {
            name = peer.name
            isLocal = (peer.peerID == interactor?.hmsSDK?.localPeer?.peerID)
        }
        
        guard let name = name else { return }

        if isLocal {
            cell.nameLabel.textAlignment = .right
            cell.messageLabel.textAlignment = .right
        } else {
            cell.nameLabel.textAlignment = .left
            cell.messageLabel.textAlignment = .left
        }

        let attributedString = NSMutableAttributedString(string: name, attributes: [.foregroundColor: UIColor.link])
        
        if let attributedSender = getSender(message) {
            attributedString.append(attributedSender)
        }
        
        cell.nameLabel.attributedText = attributedString
        cell.messageLabel.text = message.message
    }
    
    func getSender(_ message: HMSMessage) -> NSAttributedString? {
        let attributes = [ NSAttributedString.Key.foregroundColor: UIColor.black,
                           NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .body)]
        
        switch message.recipient.type {
        case .peer:
            if let name = message.recipient.peerRecipient?.name {
                return NSAttributedString(string: " (to \(name))", attributes: attributes)
            }
            fallthrough
        case .roles:
            if let role = message.recipient.rolesRecipient?.first {
                return NSAttributedString(string: " (to \(role.name))", attributes: attributes)
            }
            fallthrough
        default:
            return nil
        }
    }

    func applySnapshot(animatingDifferences: Bool = true) {

        guard let messages = interactor?.messages, let dataSource = dataSource else { return }

        var snapshot = Snapshot()

        snapshot.appendSections([.main])

        snapshot.appendItems(messages)

        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }
}

extension ChatViewController: UITextFieldDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendTapped(sendButton)
        return true
    }
}

enum ChatSection {
    case main
}

extension UITableView {

    func scrollToBottom() {

        DispatchQueue.main.async {
            let point = CGPoint(x: 0, y: self.contentSize.height + self.contentInset.bottom - self.frame.height)
            if point.y >= 0 {
                self.setContentOffset(point, animated: true)
            }
        }
    }
}
