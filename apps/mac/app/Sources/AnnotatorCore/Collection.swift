import Foundation

public enum AnnotationCollection {
    public static func isOpen(_ item: JSON) -> Bool {
        ["todo", "in_progress"].contains(item["status"].string)
    }
    public static func items(_ items: [JSON], page: String, projects: [JSON], search: String) -> [JSON] {
        let project = projects.first { "project:" + $0["id"].string == page }?["name"].string
        return items.filter { item in
            let open = isOpen(item)
            let matchesPage = page == "all" || (page == "open" && open) || (page == "done" && !open)
                || (project != nil && item["native"]["project"].string == project)
            return matchesPage && (search.isEmpty || (item["comment"].string + " " + item["element"].string).localizedCaseInsensitiveContains(search))
        }.sorted { $0["number"].int > $1["number"].int }
    }
    public static func statusTitle(_ value: String) -> String {
        switch value { case "todo": "To do"; case "in_progress": "In progress"; case "done": "Done"; default: value.replacingOccurrences(of: "_", with: " ").capitalized }
    }
}
