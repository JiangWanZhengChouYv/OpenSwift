import SwiftUI

/// 插件市场的「在线插件」分区，展示远端清单并支持刷新与下载安装。
struct PluginMarketSection: View {
    @ObservedObject private var market = PluginMarket.shared
    @ObservedObject private var store = PluginStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let error = market.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            if market.items.isEmpty {
                emptyView
            } else {
                marketList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Text("在线插件")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            if market.isFetching {
                ProgressView()
                    .controlSize(.small)
            }

            Button(action: {
                market.fetchCatalog()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(market.isFetching)
            .help("刷新在线插件列表")
        }
    }

    // MARK: - 空态 / 列表

    private var emptyView: some View {
        HStack {
            Text("尚未加载在线插件，点击刷新获取")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()

            Button("加载") {
                market.fetchCatalog()
            }
            .font(.system(size: 11))
        }
    }

    private var marketList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(market.items) { item in
                    MarketItemRow(item: item)
                }
            }
        }
        .frame(maxHeight: 180)
    }
}

/// 在线插件列表中单个插件的行视图。
private struct MarketItemRow: View {
    @ObservedObject private var market = PluginMarket.shared
    @ObservedObject private var store = PluginStore.shared

    let item: PluginMarketItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))

                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("v\(item.version)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            installButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var installButton: some View {
        if store.hasPlugin(id: item.id) {
            Text("已安装")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } else if market.downloadingPluginIDs.contains(item.id) {
            Text("下载中")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } else {
            Button("下载") {
                market.downloadPlugin(item)
            }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
        }
    }
}
