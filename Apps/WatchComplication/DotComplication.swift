import SwiftUI
import WidgetKit

private struct DotEntry: TimelineEntry { let date: Date }
private struct DotProvider: TimelineProvider {
    func placeholder(in context: Context) -> DotEntry { DotEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (DotEntry) -> Void) { completion(DotEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DotEntry>) -> Void) {
        completion(Timeline(entries: [DotEntry(date: .now)], policy: .never))
    }
}

private struct DotComplicationView: View {
    @Environment(\.widgetFamily) private var tester group
    var body: some View {
        Group {
            switch tester group {
            case .accessoryInline:
                Text("Dot")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text("Dot").font(.headline)
                    Text("Open your companion").font(.caption)
                }
            case .accessoryCorner:
                Text("Dot").font(.headline).widgetLabel { Text("Open Dot") }
            default:
                ZStack { AccessoryWidgetBackground(); Text("Dot").font(.headline) }
            }
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "dotwatch://open"))
        .accessibilityLabel("Open Dot")
    }
}

@main struct DotComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DotLauncher", provider: DotProvider()) { _ in DotComplicationView() }
            .configurationDisplayName("Dot")
            .description("Open your Dot companion.")
            .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
