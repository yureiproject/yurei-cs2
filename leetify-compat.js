(() => {
  const existingLiveField = window.__yureiGetLiveField?.();
  const getLiveStats = window.__yureiGetLiveStats;
  if (!existingLiveField || !getLiveStats || !window.__yureiSetLiveField) return;

  window.__yureiSetLiveField(function (id, provider, key) {
    if (provider !== 'leetify') return existingLiveField(id, provider, key);
    const liveStats = getLiveStats();
    const item = liveStats?.players?.[id]?.leetify;
    if (!item || item.error || !item.profile) return '—';
    const profile = item.profile;
    const stats = profile.stats || {};
    const rating = profile.rating || profile.ratings || {};
    const ranks = profile.ranks || {};
    const values = {
      winRate: profile.winrate ?? profile.win_rate ?? profile.winRate ?? stats.winrate ?? stats.win_rate,
      kd: stats.kd_ratio ?? stats.kd ?? stats.kdRatio,
      leetify_rating: ranks.leetify ?? profile.leetify_rating ?? rating.leetify ?? rating.rating,
      aim: rating.aim ?? stats.aim,
      positioning: rating.positioning ?? stats.positioning,
      utility: rating.utility ?? stats.utility,
      clutch: rating.clutch ?? stats.clutch,
      opening: rating.opening ?? stats.opening,
      trading: rating.trading ?? stats.trading ?? stats.trading_kills ?? stats.trade_kills,
      flash: stats.flash_assists ?? stats.flash_assists_per_round ?? stats.flashes_assisted,
      tRating: rating.t_leetify ?? profile.t_leetify ?? stats.t_leetify,
      ctRating: rating.ct_leetify ?? profile.ct_leetify ?? stats.ct_leetify,
      matches: profile.total_matches ?? profile.totalMatches ?? profile.matches ?? stats.matches,
    };
    return values[key] ?? existingLiveField(id, provider, key);
  });

})();
