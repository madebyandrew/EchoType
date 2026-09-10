/* EchoType landing page — nav state, staggered scroll reveals,
   hero demo loop, animated FAQ. No libraries. */
(function () {
  "use strict";

  document.body.classList.add("js");

  var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- Copy-to-clipboard buttons (download section) ---------- */
  Array.prototype.forEach.call(document.querySelectorAll("[data-copy]"), function (btn) {
    var label = btn.textContent;
    btn.addEventListener("click", function () {
      var text = btn.getAttribute("data-copy");
      function flash() {
        btn.textContent = "Copied";
        btn.classList.add("copied");
        setTimeout(function () {
          btn.textContent = label;
          btn.classList.remove("copied");
        }, 1600);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(flash, fallbackCopy);
      } else {
        fallbackCopy();
      }
      function fallbackCopy() {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.setAttribute("readonly", "");
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand("copy"); } catch (e) {}
        document.body.removeChild(ta);
        flash();
      }
    });
  });

  /* ---------- Sticky nav border on scroll ---------- */
  var nav = document.getElementById("nav");
  function onScroll() {
    nav.classList.toggle("scrolled", window.scrollY > 8);
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* ---------- Reveal on scroll, with sibling stagger ---------- */
  // Tag section furniture beyond what's marked in the HTML.
  document.querySelectorAll(
    ".eyebrow, .section-title, .privacy-copy, .not-list li, .not-closer, " +
    ".who-closer, .faq-list details, .final-cta-card"
  ).forEach(function (el) { el.classList.add("reveal"); });

  var revealEls = Array.prototype.slice.call(document.querySelectorAll(".reveal"));

  // Siblings revealed together cascade in, 70ms apart.
  revealEls.forEach(function (el) {
    var sibs = Array.prototype.filter.call(el.parentElement.children, function (c) {
      return c.classList.contains("reveal");
    });
    if (sibs.length > 1) {
      el.style.transitionDelay = Math.min(sibs.indexOf(el) * 70, 420) + "ms";
    }
  });

  function finishReveal(el) {
    // Return the element to stylesheet defaults so its own hover
    // transitions aren't slowed by the reveal timing.
    el.classList.remove("reveal", "visible");
    el.style.transitionDelay = "";
  }

  if (reducedMotion || !("IntersectionObserver" in window)) {
    revealEls.forEach(finishReveal);
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          var el = entry.target;
          el.classList.add("visible");
          io.unobserve(el);
          setTimeout(function () { finishReveal(el); }, 1200);
        }
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -40px 0px" });
    revealEls.forEach(function (el) { io.observe(el); });
  }

  /* ---------- FAQ: ease <details> open/close ---------- */
  document.querySelectorAll(".faq-list details").forEach(function (d) {
    var summary = d.querySelector("summary");
    var anim = null;
    summary.addEventListener("click", function (e) {
      if (reducedMotion) return; // native instant toggle
      e.preventDefault();
      if (anim) anim.cancel();
      d.style.overflow = "hidden";
      var start = d.offsetHeight;
      var end;
      if (d.open) {
        end = summary.offsetHeight + 2; // + borders
        anim = d.animate({ height: [start + "px", end + "px"] }, { duration: 200, easing: "ease" });
        anim.onfinish = function () { d.open = false; cleanup(); };
      } else {
        d.open = true;
        end = d.offsetHeight;
        anim = d.animate({ height: [start + "px", end + "px"] }, { duration: 220, easing: "ease" });
        anim.onfinish = cleanup;
      }
      function cleanup() { anim = null; d.style.overflow = ""; }
    });
  });

  /* ---------- Feature card fan ----------
     A vanilla port of the card-fan carousel: cards fan out like a hand,
     the hovered card lifts while its neighbors are pushed aside. */
  var fan = document.getElementById("feature-fan");
  if (fan) {
    var fanCards = Array.prototype.slice.call(fan.querySelectorAll(".fan-card"));
    var fanN = fanCards.length;
    var fanHover = null;
    var fanArmed = false;

    var fanMult = function () {
      var w = window.innerWidth;
      if (w < 480) return 0.3;
      if (w < 640) return 0.4;
      if (w < 768) return 0.55;
      if (w < 1024) return 0.78;
      return 1;
    };

    var slotCfg = function (i) {
      var half = (fanN - 1) / 2;
      var d = half > 0 ? (i - half) / half : 0;
      var a = Math.abs(d);
      return {
        rot: d * 21,
        scale: 1 - 0.2244 * a * a,
        x: d * 26,
        y: a * a * 6.5,
        z: 10 - Math.round(a * half)
      };
    };

    var applyFan = function (hovered) {
      var m = fanMult();
      fanCards.forEach(function (el, i) {
        var c = slotCfg(i);
        var x = c.x * m, y = c.y, rot = c.rot, sc = c.scale;
        if (hovered !== null) {
          if (i === hovered) {
            y -= 2.5;
            sc *= 1.08;
          } else {
            var dist = Math.abs(i - hovered);
            var push = 6 * (1 + 0.2 * Math.max(0, 3 - dist));
            if (i < hovered) { x -= push * m; rot -= 3 / (dist + 1); }
            else { x += push * m; rot += 3 / (dist + 1); }
          }
        }
        el.style.zIndex = (i === hovered) ? 20 : c.z;
        el.style.transform =
          "translate(" + x + "rem," + y + "rem) rotate(" + rot + "deg) scale(" + sc.toFixed(4) + ")";
        el.style.opacity = "1";
      });
    };

    // Pre-entrance state: stacked low, hidden.
    fanCards.forEach(function (el) {
      el.style.opacity = "0";
      el.style.transform = "translate(0, 9rem) rotate(0deg) scale(0.6)";
    });

    var armFan = function () {
      if (fanArmed) return;
      fanArmed = true;
      if (reducedMotion) { applyFan(null); return; }
      fanCards.forEach(function (el, i) {
        el.style.transitionDelay = (i * 90) + "ms";
      });
      requestAnimationFrame(function () {
        requestAnimationFrame(function () { applyFan(null); });
      });
      setTimeout(function () {
        fanCards.forEach(function (el) { el.style.transitionDelay = "0ms"; });
      }, fanN * 90 + 750);
    };

    if (reducedMotion || !("IntersectionObserver" in window)) {
      armFan();
    } else {
      var fanIo = new IntersectionObserver(function (entries) {
        if (entries[0].isIntersecting) { armFan(); fanIo.disconnect(); }
      }, { threshold: 0.25 });
      fanIo.observe(fan);
    }

    fanCards.forEach(function (el, i) {
      var lift = function () {
        if (!fanArmed || fanHover === i) return;
        fanHover = i;
        applyFan(i);
      };
      el.addEventListener("mouseenter", lift);
      el.addEventListener("focus", lift);
      el.addEventListener("touchstart", lift, { passive: true });
    });
    var settleFan = function () {
      if (!fanArmed || fanHover === null) return;
      fanHover = null;
      applyFan(null);
    };
    fan.addEventListener("mouseleave", settleFan);
    fan.addEventListener("focusout", function (e) {
      if (!fan.contains(e.relatedTarget)) settleFan();
    });
    window.addEventListener("resize", function () {
      if (fanArmed) applyFan(fanHover);
    });
  }

  /* ---------- Hero demo loop ----------
     Phases: idle → hold key (recording, waveform) → release
     (transcribing) → text types itself → pause → repeat.       */
  var demo = document.querySelector(".demo");
  var typedEl = document.getElementById("demo-typed");
  var statusText = document.getElementById("demo-status-text");
  if (!demo || !typedEl || !statusText) return;

  var SENTENCE = typedEl.textContent;

  // Reduced motion: leave the finished sentence in place, no loop.
  if (reducedMotion) {
    statusText.textContent = "Idle";
    return;
  }

  var timers = [];
  function wait(ms) {
    return new Promise(function (resolve) { timers.push(setTimeout(resolve, ms)); });
  }

  function setStatus(text) { statusText.textContent = text; }

  function typeSentence() {
    return new Promise(function (resolve) {
      var i = 0;
      function tick() {
        i += 1 + Math.floor(Math.random() * 3); // 1–3 chars, like real insertion
        typedEl.textContent = SENTENCE.slice(0, i);
        if (i < SENTENCE.length) {
          timers.push(setTimeout(tick, 24 + Math.random() * 40));
        } else {
          typedEl.textContent = SENTENCE;
          resolve();
        }
      }
      tick();
    });
  }

  function runLoop() {
    typedEl.textContent = "";
    setStatus("Idle");
    demo.className = "demo";

    wait(1400)
      .then(function () {                 // key goes down → recording
        demo.classList.add("recording");
        setStatus("\u{1F534} Recording");
        return wait(2600);
      })
      .then(function () {                 // key released → transcribing
        demo.classList.remove("recording");
        demo.classList.add("transcribing");
        setStatus("✍️ Transcribing…");
        return wait(900);
      })
      .then(function () {                 // words appear at the cursor
        demo.classList.remove("transcribing");
        setStatus("Idle");
        return typeSentence();
      })
      .then(function () { return wait(3800); })
      .then(runLoop);
  }

  // Pause the loop when the tab is hidden to save cycles.
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) {
      timers.forEach(clearTimeout);
      timers = [];
    } else {
      runLoop();
    }
  });

  runLoop();
})();
