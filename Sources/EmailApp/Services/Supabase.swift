import Foundation
import Supabase

/// The Supabase project Maily talks to.
///
/// Both values below are safe in a shipped binary. The anon key is a public,
/// non-secret JWT whose only claim is `role: anon` -- every table it can reach
/// is gated by Row Level Security on the server. The `service_role` key is the
/// dangerous one and must never appear in this repo or in the app: it bypasses
/// RLS entirely, and anyone can pull strings out of an .ipa.
enum SupabaseConfig {
    static let url = URL(string: "https://mhdudbprqbzudpshriyb.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1oZHVkYnBycWJ6dWRwc2hyaXliIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgwOTQ4NzIsImV4cCI6MjEwMzY3MDg3Mn0.JQZBVr3Rs9vrYEOYFOEOHH-fcdng6P5GwiX3FdwIHC8"
}

extension SupabaseClient {
    static let shared = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.anonKey
    )
}
