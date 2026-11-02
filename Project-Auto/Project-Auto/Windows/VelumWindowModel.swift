//
//  VelumWindowModel.swift
//  Project-Auto
//
//  每个应用窗口一份的窗口状态（导航、页面搜索、提示）。
//  会话与消息由 AgentChatModel 持有；应用级偏好由 AppSettings 持有。
//

import Combine
import Foundation

final class VelumWindowModel: ObservableObject {
    // 导航
    @Published var selectedTab: VelumTab = .workspace
    @Published var navigationHistory: [VelumTab] = []
    @Published var detailsVisible = false

    // 页面状态
    @Published var searchText = ""
    @Published var showNotification = false

    // 仅用于本地截图与验收：`--details` 强制展开任务详情。
    init(initialTab: VelumTab = .workspace) {
        selectedTab = initialTab
        let showByDefault = UserDefaults.standard.bool(forKey: AppSettings.defaultShowDetailsKey)
        detailsVisible = showByDefault
    }

    func navigate(to destination: VelumTab) {
        guard destination != selectedTab else { return }
        navigationHistory.append(selectedTab)
        selectedTab = destination
        detailsVisible = false
    }

    func goBack() {
        guard let previousPage = navigationHistory.popLast() else { return }
        selectedTab = previousPage
        detailsVisible = false
    }
}
