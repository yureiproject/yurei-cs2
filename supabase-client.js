// Safe to publish: this is the project URL and publishable (public) key.
// Authorization comes from Supabase Auth sessions and the database RLS policies.
window.yureiSupabase = window.supabase.createClient(
  'https://dziwedssqmojnhbsjslz.supabase.co',
  'sb_publishable_ByBN_asd6mFMh71ABV-gfA_bUwVBTq2',
  {
    auth: {
      autoRefreshToken: true,
      // Electron sends auth callbacks through yurei:// and exchanges them explicitly.
      // Keep automatic URL detection for a normal web preview.
      detectSessionInUrl: !window.yureiDesktop,
      persistSession: true,
      flowType: 'pkce',
    },
  },
)
