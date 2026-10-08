import Foundation

/// The JavaScript injected into every page of the StudyDesk web app.
///
/// Two scripts, kept as plain strings so they can be reviewed and tested
/// without compiling:
///
/// 1. `bridgeBootstrap` (document-start): defines `window.StudyDeskNative`
///    as a promise-based wrapper around the single WKScriptMessageHandler
///    `studydesk`. WKScriptMessageHandler is callback-based, so the native
///    side replies by evaluating `window.__sdResolve(id, jsonValue)` or
///    `window.__sdReject(id, message)`. Each call has a 30s timeout.
///
/// 2. `timerHook` (document-end, on every finished navigation + a delayed
///    retry): if the page exposes `window.Timer` (the focus-timer object —
///    INFERRED from the Android bridge contract, whose timerSync takes the
///    11-arg signature below), its methods are wrapped so every mutation
///    pushes a timerSync back into native, and a 5s poll runs while a
///    session is active. If `window.Timer` is absent, nothing happens.
enum BridgeScript {
    /// Contract with native: each bridge method is exposed here with the
    /// exact argument order the native router expects.
    static let bridgeBootstrap = """
    (function () {
      'use strict';
      if (window.StudyDeskNative) { return; }

      var pending = {};
      var seq = 0;
      var TIMEOUT_MS = 30000;

      window.__sdResolve = function (id, value) {
        var p = pending[id];
        if (p) { delete pending[id]; clearTimeout(p.timer); p.resolve(value); }
      };
      window.__sdReject = function (id, message) {
        var p = pending[id];
        if (p) { delete pending[id]; clearTimeout(p.timer); p.reject(new Error(String(message))); }
      };

      function call(method, args) {
        return new Promise(function (resolve, reject) {
          var id = 'm' + (++seq) + '_' + Date.now();
          var timer = setTimeout(function () {
            if (pending[id]) { delete pending[id]; reject(new Error('StudyDeskNative.' + method + ' timed out')); }
          }, TIMEOUT_MS);
          pending[id] = { resolve: resolve, reject: reject, timer: timer };
          try {
            window.webkit.messageHandlers.studydesk.postMessage({ id: id, method: method, args: args || [] });
          } catch (e) {
            delete pending[id];
            clearTimeout(timer);
            reject(e);
          }
        });
      }

      window.StudyDeskNative = {
        available: function () { return call('available'); },
        localAvailable: function () { return call('localAvailable'); },
        isOnline: function () { return call('isOnline'); },
        requestNotificationPermission: function () { return call('requestNotificationPermission'); },
        notify: function (title, body, opts) { return call('notify', [title, body, opts]); },
        schedule: function (title, body, atMs, key, route, url, type) {
          return call('schedule', [title, body, atMs, key, route, url, type]);
        },
        cancel: function (key) { return call('cancel', [key]); },
        scheduleDailyComeback: function (hour, minute) { return call('scheduleDailyComeback', [hour, minute]); },
        focusCycleNotify: function (phase, text) { return call('focusCycleNotify', [phase, text]); },
        ttsAvailable: function () { return call('ttsAvailable'); },
        ttsSpeak: function (text, rate) { return call('ttsSpeak', [text, rate]); },
        ttsStop: function () { return call('ttsStop'); },
        registerPush: function () { return call('registerPush'); },
        haptic: function (style) { return call('haptic', [style]); },
        share: function (payload) { return call('share', [payload]); },
        open: function (url) { return call('open', [url]); },
        openExternal: function (url) { return call('openExternal', [url]); },
        enterImmersive: function () { return call('enterImmersive'); },
        exitImmersive: function () { return call('exitImmersive'); },
        setKeepAwake: function (on) { return call('setKeepAwake', [on]); },
        timerSync: function (phase, running, sessionActive, countUp, elapsedSec, targetSec, subject, mode, round, maxRounds) {
          return call('timerSync', [phase, running, sessionActive, countUp, elapsedSec, targetSec, subject, mode, round, maxRounds]);
        },
        timerStop: function () { return call('timerStop'); }
      };
    })();
    """

    /// Hooks the page's timer object (if present) so native gets timerSync
    /// on every mutation. Idempotent via `__sdHooked`.
    ///
    /// NOTE (INFERRED): the exact `window.Timer` field names (phase, running,
    /// sessionActive, countUp, elapsedSec, targetSec, subject, mode, round,
    /// maxRounds) are inferred from the Android bridge's 11-arg timerSync
    /// contract, not verified against the live dashboard.php.
    static let timerHook = """
    (function () {
      'use strict';
      try {
        var T = window.Timer;
        if (!T || T.__sdHooked || !window.StudyDeskNative) { return; }
        T.__sdHooked = true;

        function sync() {
          try {
            window.StudyDeskNative.timerSync(
              T.phase, T.running, T.sessionActive, T.countUp,
              T.elapsedSec, T.targetSec, T.subject, T.mode,
              T.round, T.maxRounds
            );
          } catch (e) { /* bridge not ready; the poll will retry */ }
        }

        ['start', 'pause', 'reset', 'hardReset', 'skip', 'finishCycleOrRound'].forEach(function (name) {
          if (typeof T[name] === 'function') {
            var orig = T[name];
            T[name] = function () {
              var r = orig.apply(T, arguments);
              try { sync(); } catch (e) {}
              return r;
            };
          }
        });

        if (typeof T.tick === 'function') {
          var origTick = T.tick;
          T.tick = function () {
            var r = origTick.apply(T, arguments);
            try { if (T.running || T.sessionActive) { sync(); } } catch (e) {}
            return r;
          };
        }

        // Poll while a session is active so the Live Activity / banner
        // stays fresh even if tick() isn't called by the page every second.
        setInterval(function () {
          try { if (T.running || T.sessionActive) { sync(); } } catch (e) {}
        }, 5000);

        sync();
      } catch (e) { /* never let the hook break the page */ }
    })();
    """
}
