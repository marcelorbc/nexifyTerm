import SwiftUI

/// Tecnologias que conseguimos inferir listando arquivos da raiz de um
/// repositório (e, em alguns casos, lendo `package.json`/`pyproject.toml`).
/// Repos podem ter múltiplas — ex.: `[react, typescript, tailwind]` —
/// então o detector retorna um `Set<RepoTech>`.
enum RepoTech: String, CaseIterable, Identifiable, Codable, Hashable {
    // Frontend frameworks
    case react, vue, angular, svelte, nextjs, nuxt
    // Web/UI helpers
    case typescript, javascript, tailwind, html

    // Backends / runtimes
    case nodejs
    case python, django, flask, fastapi
    case java, kotlin, gradle, maven
    case go
    case rust
    case ruby, rails
    case php, laravel
    case dotnet
    case swift
    case dart, flutter

    // Mobile
    case ios, android, reactNative

    // Infra / DevOps
    case docker, k8s, terraform, ansible

    // Data / ML
    case jupyter

    // Tooling
    case monorepo

    // Generic / legacy
    case shell

    var id: String { rawValue }

    /// Texto exibido no chip / badge.
    var label: String {
        switch self {
        case .react:        return "React"
        case .vue:          return "Vue"
        case .angular:      return "Angular"
        case .svelte:       return "Svelte"
        case .nextjs:       return "Next.js"
        case .nuxt:         return "Nuxt"
        case .typescript:   return "TypeScript"
        case .javascript:   return "JavaScript"
        case .tailwind:     return "Tailwind"
        case .html:         return "HTML"
        case .nodejs:       return "Node.js"
        case .python:       return "Python"
        case .django:       return "Django"
        case .flask:        return "Flask"
        case .fastapi:      return "FastAPI"
        case .java:         return "Java"
        case .kotlin:       return "Kotlin"
        case .gradle:       return "Gradle"
        case .maven:        return "Maven"
        case .go:           return "Go"
        case .rust:         return "Rust"
        case .ruby:         return "Ruby"
        case .rails:        return "Rails"
        case .php:          return "PHP"
        case .laravel:      return "Laravel"
        case .dotnet:       return ".NET"
        case .swift:        return "Swift"
        case .dart:         return "Dart"
        case .flutter:      return "Flutter"
        case .ios:          return "iOS"
        case .android:      return "Android"
        case .reactNative:  return "React Native"
        case .docker:       return "Docker"
        case .k8s:          return "Kubernetes"
        case .terraform:    return "Terraform"
        case .ansible:      return "Ansible"
        case .jupyter:      return "Jupyter"
        case .monorepo:     return "Monorepo"
        case .shell:        return "Shell"
        }
    }

    /// Cor do badge. Tons baseados no SO macOS dark mode pra contrastar.
    var color: Color {
        switch self {
        case .react, .reactNative:  return Color(red: 0.38, green: 0.78, blue: 0.93)
        case .vue, .nuxt:           return Color(red: 0.26, green: 0.71, blue: 0.51)
        case .angular:              return Color(red: 0.86, green: 0.20, blue: 0.20)
        case .svelte:               return Color(red: 0.96, green: 0.36, blue: 0.13)
        case .nextjs:               return Color(red: 0.55, green: 0.55, blue: 0.55)
        case .typescript:           return Color(red: 0.18, green: 0.48, blue: 0.78)
        case .javascript:           return .yellow
        case .tailwind:             return Color(red: 0.15, green: 0.69, blue: 0.78)
        case .html:                 return Color(red: 0.91, green: 0.40, blue: 0.20)
        case .nodejs:               return Color(red: 0.36, green: 0.66, blue: 0.34)
        case .python, .django, .flask, .fastapi, .jupyter:
            return Color(red: 0.22, green: 0.49, blue: 0.72)
        case .java, .gradle, .maven: return Color(red: 0.65, green: 0.34, blue: 0.13)
        case .kotlin:               return Color(red: 0.62, green: 0.27, blue: 0.85)
        case .go:                   return Color(red: 0.07, green: 0.69, blue: 0.81)
        case .rust:                 return Color(red: 0.86, green: 0.42, blue: 0.20)
        case .ruby, .rails:         return Color(red: 0.78, green: 0.20, blue: 0.20)
        case .php, .laravel:        return Color(red: 0.30, green: 0.27, blue: 0.55)
        case .dotnet:               return Color(red: 0.34, green: 0.47, blue: 0.78)
        case .swift, .ios:          return .orange
        case .dart, .flutter:       return Color(red: 0.16, green: 0.55, blue: 0.78)
        case .android:              return Color(red: 0.42, green: 0.69, blue: 0.16)
        case .docker:               return Color(red: 0.16, green: 0.55, blue: 0.85)
        case .k8s:                  return Color(red: 0.24, green: 0.40, blue: 0.85)
        case .terraform:            return Color(red: 0.40, green: 0.27, blue: 0.78)
        case .ansible:              return Color(red: 0.78, green: 0.10, blue: 0.10)
        case .monorepo:             return Color(red: 0.54, green: 0.42, blue: 0.78)
        case .shell:                return Color(red: 0.45, green: 0.45, blue: 0.45)
        }
    }

    /// Categoria — usada para agrupar chips na UI ("Frontend", "Backend"…).
    enum Category: String, CaseIterable {
        case frontend = "Frontend"
        case backend = "Backend"
        case mobile = "Mobile"
        case infra = "Infra"
        case other = "Outros"
    }

    var category: Category {
        switch self {
        case .react, .vue, .angular, .svelte, .nextjs, .nuxt,
             .typescript, .javascript, .tailwind, .html:
            return .frontend
        case .nodejs, .python, .django, .flask, .fastapi,
             .java, .kotlin, .gradle, .maven, .go, .rust,
             .ruby, .rails, .php, .laravel, .dotnet:
            return .backend
        case .swift, .ios, .android, .dart, .flutter, .reactNative:
            return .mobile
        case .docker, .k8s, .terraform, .ansible:
            return .infra
        case .jupyter, .monorepo, .shell:
            return .other
        }
    }
}
