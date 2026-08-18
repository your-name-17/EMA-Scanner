// ==UserScript==
// @name         PerpScope Binance Browser
// @namespace    perpscope
// @version      0.4.0
// @description  PerpScope 顺序浏览：每次新开 3 个标签，不覆盖已有标签页。
// @match        https://www.binance.com/*
// @match        https://binance.com/*
// @match        https://*.binance.com/*
// @match        http://localhost:*/*
// @match        https://localhost:*/*
// @match        http://127.0.0.1:*/*
// @match        https://127.0.0.1:*/*
// @grant        GM_setValue
// @grant        GM_getValue
// ==/UserScript==

(function () {
  'use strict';

  const QUEUE_KEY = 'perpscopeBrowseQueue';
  const EVENT_NAME = 'perpscope-browse-queue-updated';
  const STATE_KEY = 'perpscopeBrowseState';
  const STEP = 3;

  const isBinance = location.hostname.includes('binance.com');
  const isPerpScopeLocal =
    location.hostname === 'localhost' || location.hostname === '127.0.0.1';

  function toast(text) {
    try {
      const el = document.createElement('div');
      el.textContent = text;
      el.style.cssText =
        'position:fixed;right:16px;bottom:16px;z-index:999999;' +
        'background:rgba(0,0,0,0.75);color:#fff;padding:8px 10px;' +
        'border-radius:8px;font-size:12px;line-height:1.4;';
      document.body.appendChild(el);
      setTimeout(() => el.remove(), 1600);
    } catch (_) {}
  }

  function safeParse(text, fallback = null) {
    if (!text) return fallback;
    try {
      return JSON.parse(text);
    } catch (_) {
      return fallback;
    }
  }

  function getQueue() {
    return normalizeQueue(safeParse(GM_getValue(QUEUE_KEY, ''), null));
  }

  function getState() {
    return safeParse(GM_getValue(STATE_KEY, ''), null);
  }

  function setState(state) {
    GM_setValue(STATE_KEY, JSON.stringify(state));
  }

  function tabName(index) {
    return 'perpscope_' + index;
  }

  function normalizeQueue(queue) {
    if (!queue || !Array.isArray(queue.symbols) || !Array.isArray(queue.urls)) {
      return null;
    }
    if (queue.symbols.length !== queue.urls.length || queue.symbols.length === 0) {
      return null;
    }
    const currentIndex =
      typeof queue.currentIndex === 'number' ? queue.currentIndex : 0;
    return {
      symbols: queue.symbols.slice(),
      urls: queue.urls.slice(),
      currentIndex: Math.max(0, Math.min(currentIndex, queue.urls.length - 1)),
      linkMode: queue.linkMode || 'futures',
      updatedAt: queue.updatedAt || new Date().toISOString(),
    };
  }

  function getCurrentIndex(queue) {
    const state = getState();
    if (state && typeof state.currentIndex === 'number') {
      return Math.max(0, Math.min(state.currentIndex, queue.urls.length - 1));
    }
    return queue.currentIndex;
  }

  function tryConsumeQueueFromUrlHash() {
    if (!isBinance) return false;
    const hash = location.hash || '';
    const marker = '#perpscope_queue=';
    if (!hash.startsWith(marker)) return false;

    const queue = normalizeQueue(
      safeParse(decodeURIComponent(hash.slice(marker.length)), null),
    );
    if (!queue) {
      toast('PerpScope 队列参数无效');
      return false;
    }

    GM_setValue(QUEUE_KEY, JSON.stringify(queue));
    setState({
      currentIndex: queue.currentIndex,
      updatedAt: queue.updatedAt,
    });
    history.replaceState(null, '', location.pathname + location.search);
    toast(`PerpScope 队列已注入（${queue.urls.length}）`);
    return true;
  }

  function openBatch(startIndex) {
    const queue = getQueue();
    if (!queue) {
      toast('队列为空：先回 PerpScope 点“开始浏览”');
      return;
    }

    const nextIndex = Math.max(0, Math.min(startIndex, queue.urls.length - 1));
    const batchEnd = Math.min(queue.urls.length, nextIndex + STEP);

    setState({
      currentIndex: nextIndex,
      updatedAt: new Date().toISOString(),
    });

    let opened = 0;
    for (let i = nextIndex; i < batchEnd; i += 1) {
      const name = tabName(i);
      if (window.name === name) continue;
      window.open(queue.urls[i], name);
      opened += 1;
    }

    toast(
      `打开 ${nextIndex + 1}-${batchEnd}/${queue.urls.length}` +
        (opened === 0 ? '（当前批次已打开）' : ''),
    );
  }

  function moveBy(delta) {
    const queue = getQueue();
    if (!queue) {
      toast('队列为空：先回 PerpScope 点“开始浏览”');
      return;
    }
    openBatch(getCurrentIndex(queue) + delta);
  }

  function mountQuickButtons() {
    if (!isBinance || document.getElementById('perpscope-quick-buttons')) return;

    const wrap = document.createElement('div');
    wrap.id = 'perpscope-quick-buttons';
    wrap.style.cssText =
      'position:fixed;right:16px;bottom:56px;z-index:999999;' +
      'display:flex;gap:8px;pointer-events:auto;';

    const mkBtn = (text, onClick) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.textContent = text;
      btn.style.cssText =
        'background:rgba(0,0,0,0.75);color:#fff;border:1px solid rgba(255,255,255,0.35);' +
        'padding:6px 10px;border-radius:6px;cursor:pointer;font-size:12px;';
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        onClick();
      });
      return btn;
    };

    wrap.appendChild(mkBtn('Prev -3', () => moveBy(-STEP)));
    wrap.appendChild(mkBtn('Next +3', () => moveBy(STEP)));
    document.body.appendChild(wrap);
  }

  function bindPerpScopeBridge() {
    const syncQueue = () => {
      const raw = localStorage.getItem(QUEUE_KEY);
      const queue = normalizeQueue(safeParse(raw, null));
      if (!queue) {
        GM_setValue(QUEUE_KEY, '');
        GM_setValue(STATE_KEY, '');
        return;
      }
      GM_setValue(QUEUE_KEY, JSON.stringify(queue));
      setState({
        currentIndex: queue.currentIndex,
        updatedAt: queue.updatedAt,
      });
    };

    window.addEventListener(EVENT_NAME, syncQueue);
    syncQueue();
  }

  function bindBinanceControls() {
    const handleKeydown = (event) => {
      const target = event.target;
      const tag = (target && target.tagName) || '';
      const isEditable =
        tag === 'INPUT' ||
        tag === 'TEXTAREA' ||
        tag === 'SELECT' ||
        (target &&
          typeof target.closest === 'function' &&
          target.closest('[contenteditable="true"]'));
      if (
        isEditable ||
        event.isComposing ||
        event.ctrlKey ||
        event.metaKey ||
        event.altKey
      ) {
        return;
      }

      if (
        event.key === ']' ||
        event.key === 'ArrowRight' ||
        event.key === 'j' ||
        event.key === 'J' ||
        event.key === 'PageDown'
      ) {
        event.preventDefault();
        event.stopPropagation();
        moveBy(STEP);
      } else if (
        event.key === '[' ||
        event.key === 'ArrowLeft' ||
        event.key === 'k' ||
        event.key === 'K' ||
        event.key === 'PageUp'
      ) {
        event.preventDefault();
        event.stopPropagation();
        moveBy(-STEP);
      }
    };

    window.addEventListener('keydown', handleKeydown, true);
    document.addEventListener('keydown', handleKeydown, true);
    mountQuickButtons();

    const queue = getQueue();
    if (queue) {
      toast(`PerpScope 就绪，队列 ${queue.urls.length} 个`);
    } else {
      toast('PerpScope 脚本已加载，等待队列...');
    }
  }

  if (isPerpScopeLocal) {
    bindPerpScopeBridge();
  }

  if (isBinance) {
    tryConsumeQueueFromUrlHash();
    bindBinanceControls();
  }
})();
