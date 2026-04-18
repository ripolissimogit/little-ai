import Foundation

enum ActionType: String, CaseIterable, Identifiable {
    case correct
    case extend
    case reduce
    case tone
    case translate
    case generate

    var id: String { rawValue }
}

enum Tone: String, CaseIterable, Identifiable {
    case formal
    case informal
    case professional
    case friendly
    case technical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .formal: return "Formale"
        case .informal: return "Informale"
        case .professional: return "Professionale"
        case .friendly: return "Amichevole"
        case .technical: return "Tecnico"
        }
    }
}
