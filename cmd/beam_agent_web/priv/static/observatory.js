// Vanilla, dependency-free. Reads the JSON payload the server embedded in
// #obs-data and renders it as: a force-directed "constellation" graph (own
// tiny physics loop, no external layout library), a Signal Inspector side
// panel, and a hand-rolled CSS3D "exploded" directory-rings view. Nothing
// here calls the network; everything is derived from data already on the
// page. HTML is only ever built from values the server already escaped, or
// set via textContent — never string-concatenated from report data.
(function () {
  "use strict";

  var dataNode = document.getElementById("obs-data");
  if (!dataNode) return;

  var report;
  try {
    report = JSON.parse(dataNode.textContent);
  } catch (e) {
    return;
  }

  var nodes = (report.constellation && report.constellation.nodes) || [];
  var edges = (report.constellation && report.constellation.edges) || [];
  var byPath = {};
  nodes.forEach(function (n) {
    byPath[n.path] = n;
  });

  wireTabs();
  var graph = buildGraph(nodes, edges);
  wireSelection(graph);
  if (nodes.length) selectNode(graph, nodes[0].path);
  buildExploded(nodes, graph);

  // ---- Tabs ---------------------------------------------------------
  function wireTabs() {
    var tabs = document.querySelectorAll(".observatory-tab");
    var panels = document.querySelectorAll("[data-tab-panel]");

    tabs.forEach(function (tab) {
      tab.addEventListener("click", function () {
        tabs.forEach(function (t) {
          t.classList.toggle("active", t === tab);
        });
        panels.forEach(function (p) {
          p.hidden = p.getAttribute("data-tab-panel") !== tab.getAttribute("data-tab");
        });
      });
    });
  }

  // ---- Constellation graph -------------------------------------------
  function buildGraph(nodes, edges) {
    var host = document.getElementById("obs-graph");
    if (!host || nodes.length === 0) return null;

    var W = 1000,
      H = 1000;
    var index = {};
    var sim = nodes.map(function (n, i) {
      var angle = (i / nodes.length) * Math.PI * 2;
      var r = 120 + Math.random() * 80;
      index[n.path] = i;
      return {
        node: n,
        x: W / 2 + Math.cos(angle) * r,
        y: H / 2 + Math.sin(angle) * r,
        vx: 0,
        vy: 0
      };
    });

    var links = edges
      .map(function (e) {
        var a = index[e.source],
          b = index[e.target];
        return a === undefined || b === undefined ? null : { a: a, b: b, weight: e.weight };
      })
      .filter(Boolean);

    var maxCommits = nodes.reduce(function (m, n) {
      return Math.max(m, n.commits || 0);
    }, 1);

    runSimulation(sim, links, W, H);

    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 " + W + " " + H);

    var edgeGroup = document.createElementNS(svg.namespaceURI, "g");
    var nodeGroup = document.createElementNS(svg.namespaceURI, "g");

    var edgeEls = links.map(function (link) {
      var line = document.createElementNS(svg.namespaceURI, "line");
      line.setAttribute("class", "observatory-edge");
      line.setAttribute("x1", sim[link.a].x);
      line.setAttribute("y1", sim[link.a].y);
      line.setAttribute("x2", sim[link.b].x);
      line.setAttribute("y2", sim[link.b].y);
      edgeGroup.appendChild(line);
      return { el: line, link: link };
    });

    var nodeEls = sim.map(function (entry) {
      var radius = 8 + (entry.node.commits / maxCommits) * 16;
      var g = document.createElementNS(svg.namespaceURI, "g");
      g.setAttribute("class", "observatory-node");
      g.setAttribute("transform", "translate(" + entry.x + "," + entry.y + ")");
      g.dataset.path = entry.node.path;

      var circle = document.createElementNS(svg.namespaceURI, "circle");
      circle.setAttribute("r", radius);
      g.appendChild(circle);

      var label = document.createElementNS(svg.namespaceURI, "text");
      label.setAttribute("x", radius + 6);
      label.setAttribute("y", 4);
      label.textContent = baseName(entry.node.path);
      g.appendChild(label);

      nodeGroup.appendChild(g);
      return { el: g, entry: entry };
    });

    svg.appendChild(edgeGroup);
    svg.appendChild(nodeGroup);
    host.innerHTML = "";
    host.appendChild(svg);

    wireDrag(host, svg);

    return { svg: svg, nodeEls: nodeEls, edgeEls: edgeEls, byPath: index };
  }

  function runSimulation(sim, links, W, H) {
    var iterations = 220;
    var repulsion = 2600;
    var center = { x: W / 2, y: H / 2 };

    for (var step = 0; step < iterations; step++) {
      var cooling = 1 - step / iterations;

      for (var i = 0; i < sim.length; i++) {
        for (var j = i + 1; j < sim.length; j++) {
          var dx = sim[i].x - sim[j].x;
          var dy = sim[i].y - sim[j].y;
          var distSq = Math.max(dx * dx + dy * dy, 1);
          var force = (repulsion / distSq) * cooling;
          var dist = Math.sqrt(distSq);
          var fx = (dx / dist) * force;
          var fy = (dy / dist) * force;
          sim[i].vx += fx;
          sim[i].vy += fy;
          sim[j].vx -= fx;
          sim[j].vy -= fy;
        }

        sim[i].vx += (center.x - sim[i].x) * 0.002;
        sim[i].vy += (center.y - sim[i].y) * 0.002;
      }

      links.forEach(function (link) {
        var a = sim[link.a],
          b = sim[link.b];
        var dx = b.x - a.x,
          dy = b.y - a.y;
        var dist = Math.max(Math.sqrt(dx * dx + dy * dy), 1);
        var target = 90;
        var pull = (dist - target) * 0.02 * Math.min(link.weight, 6);
        var fx = (dx / dist) * pull;
        var fy = (dy / dist) * pull;
        a.vx += fx;
        a.vy += fy;
        b.vx -= fx;
        b.vy -= fy;
      });

      for (var k = 0; k < sim.length; k++) {
        sim[k].vx *= 0.82;
        sim[k].vy *= 0.82;
        sim[k].x = clamp(sim[k].x + sim[k].vx, 40, W - 40);
        sim[k].y = clamp(sim[k].y + sim[k].vy, 40, H - 40);
      }
    }
  }

  function wireDrag(host, svg) {
    var dragging = false,
      last = null,
      pan = { x: 0, y: 0 },
      zoom = 1;

    host.addEventListener("pointerdown", function (e) {
      dragging = true;
      last = { x: e.clientX, y: e.clientY };
      host.setPointerCapture(e.pointerId);
    });

    host.addEventListener("pointermove", function (e) {
      if (!dragging) return;
      pan.x += e.clientX - last.x;
      pan.y += e.clientY - last.y;
      last = { x: e.clientX, y: e.clientY };
      applyTransform();
    });

    ["pointerup", "pointerleave", "pointercancel"].forEach(function (type) {
      host.addEventListener(type, function () {
        dragging = false;
      });
    });

    host.addEventListener(
      "wheel",
      function (e) {
        e.preventDefault();
        zoom = clamp(zoom * (e.deltaY < 0 ? 1.08 : 0.93), 0.4, 3);
        applyTransform();
      },
      { passive: false }
    );

    function applyTransform() {
      svg.style.transform = "translate(" + pan.x + "px," + pan.y + "px) scale(" + zoom + ")";
    }
  }

  function baseName(path) {
    var parts = path.split("/");
    return parts[parts.length - 1];
  }

  // ---- Selection / Signal Inspector -----------------------------------
  function wireSelection(graph) {
    if (graph) {
      graph.nodeEls.forEach(function (item) {
        item.el.addEventListener("click", function () {
          selectNode(graph, item.entry.node.path);
        });
      });
    }

    document.querySelectorAll("[data-select-path]").forEach(function (el) {
      el.addEventListener("click", function () {
        var path = el.getAttribute("data-select-path");
        document.querySelectorAll('.observatory-tab[data-tab="constellation"]')[0].click();
        selectNode(graph, path);
      });
    });
  }

  function selectNode(graph, path) {
    var node = byPath[path];
    if (!node) return;

    if (graph) {
      var selectedIndex = graph.byPath[path];

      graph.nodeEls.forEach(function (item) {
        item.el.classList.toggle("selected", item.entry.node.path === path);
      });
      graph.edgeEls.forEach(function (item) {
        var lit = item.link.a === selectedIndex || item.link.b === selectedIndex;
        item.el.classList.toggle("lit", lit);
      });
    }

    renderInspector(node, graph);
  }

  function renderInspector(node, graph) {
    var host = document.getElementById("obs-inspector");
    if (!host) return;

    var neighbors = [];
    if (graph) {
      edges.forEach(function (e) {
        if (e.source === node.path) neighbors.push({ path: e.target, weight: e.weight });
        else if (e.target === node.path) neighbors.push({ path: e.source, weight: e.weight });
      });
      neighbors.sort(function (a, b) {
        return b.weight - a.weight;
      });
    }

    host.innerHTML = "";

    var h3 = document.createElement("h3");
    h3.textContent = baseName(node.path);
    var p = document.createElement("p");
    p.className = "path";
    p.textContent = node.path;
    var stat = document.createElement("p");
    stat.className = "stat-line";
    stat.textContent =
      node.commits + " sampled commit" + (node.commits === 1 ? "" : "s") + " · " + formatBytes(node.size) + " · " + node.language;

    var coverage = document.createElement("p");
    coverage.className = "coverage " + (node.has_test ? "present" : "missing");
    coverage.textContent = node.has_test
      ? "A matching test file was found."
      : "No matching test filename found. Coverage is unknown.";

    host.appendChild(h3);
    host.appendChild(p);
    host.appendChild(stat);
    host.appendChild(coverage);

    if (neighbors.length) {
      var h4 = document.createElement("h4");
      h4.textContent = "Often changes with";
      host.appendChild(h4);

      var ul = document.createElement("ul");
      neighbors.slice(0, 6).forEach(function (n) {
        var li = document.createElement("li");
        var name = document.createElement("span");
        name.textContent = n.path;
        var count = document.createElement("span");
        count.textContent = n.weight + " commits";
        li.appendChild(name);
        li.appendChild(count);
        ul.appendChild(li);
      });
      host.appendChild(ul);
    }

    var button = document.createElement("button");
    button.type = "button";
    button.className = "observatory-investigate";
    button.textContent = "Prepare investigation ↗";
    button.addEventListener("click", function () {
      var note = document.createElement("p");
      note.className = "muted";
      note.style.marginTop = "10px";
      note.textContent =
        "Ask your harness: \u201cinvestigate " + node.path + ", it changes with " +
        (neighbors[0] ? neighbors[0].path : "related files") + " and has " +
        (node.has_test ? "a test file" : "no detected test coverage") + ".\u201d";
      host.appendChild(note);
    });
    host.appendChild(button);
  }

  function formatBytes(bytes) {
    if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + " MB";
    if (bytes >= 1024) return (bytes / 1024).toFixed(1) + " KB";
    return bytes + " B";
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  // ---- Exploded 3D assembly --------------------------------------------
  function buildExploded(nodes, graph) {
    var host = document.getElementById("obs-exploded");
    if (!host || nodes.length === 0) return;

    var groups = {};
    nodes.forEach(function (n) {
      var top = n.path.indexOf("/") === -1 ? "." : n.path.split("/")[0];
      (groups[top] = groups[top] || []).push(n);
    });

    var groupNames = Object.keys(groups).sort(function (a, b) {
      return groups[b].length - groups[a].length;
    });

    var rig = document.createElement("div");
    rig.className = "observatory-exploded-rig";

    groupNames.forEach(function (name, ringIndex) {
      var files = groups[name];
      var radius = 90 + ringIndex * 70;
      var depth = ringIndex * -90;
      var diameter = radius * 2;

      var ring = document.createElement("div");
      ring.className = "observatory-ring";
      ring.style.width = diameter + "px";
      ring.style.height = diameter + "px";
      ring.style.left = "50%";
      ring.style.top = "50%";
      // Absolutely-positioned children of a `place-items: center` grid don't
      // reliably inherit that centering, so pin the ring explicitly: shift
      // back by half its own size before applying the ring's Z-depth.
      ring.style.transform =
        "translate(-50%, -50%) translateZ(" + depth + "px)";

      var label = document.createElement("span");
      label.className = "observatory-ring-label";
      label.textContent = name + " / " + files.length;
      ring.appendChild(label);

      var capped = files.slice(0, 24);
      capped.forEach(function (file, i) {
        var angle = (i / capped.length) * Math.PI * 2;
        var size = 14 + Math.min(file.commits, 12) * 2;
        var cog = document.createElement("div");
        cog.className = "observatory-cog";
        cog.style.width = size + "px";
        cog.style.height = size + "px";
        cog.style.left = radius - size / 2 + "px";
        cog.style.top = radius - size / 2 + "px";
        cog.style.transform =
          "rotate(" + angle + "rad) translate(" + radius + "px) rotate(" + -angle + "rad)";
        cog.style.background = colorFor(file.language);
        cog.title = file.path + " · " + file.commits + " commits";
        var b = document.createElement("b");
        b.textContent = "";
        cog.appendChild(b);
        cog.addEventListener("click", function () {
          document.querySelectorAll('.observatory-tab[data-tab="constellation"]')[0].click();
          selectNode(graph, file.path);
        });
        ring.appendChild(cog);
      });

      rig.appendChild(ring);
    });

    host.innerHTML = "";
    host.appendChild(rig);

    var hint = document.createElement("span");
    hint.className = "observatory-exploded-hint";
    hint.textContent = "drag to rotate · scroll to zoom";
    host.appendChild(hint);

    wireOrbit(host, rig);
  }

  function colorFor(language) {
    var palette = {
      elixir: "#a4e3c2",
      javascript: "#f4d58d",
      typescript: "#7ec8e3",
      python: "#9ad0c2",
      go: "#8fd9ff",
      rust: "#e39a9a",
      text: "#b5a1ed"
    };
    return palette[language] || "#9ba5b9";
  }

  function wireOrbit(host, rig) {
    var rotX = -18,
      rotY = 24,
      scale = 1;
    var dragging = false,
      last = null;
    var autoSpin = true;

    apply();

    host.addEventListener("pointerdown", function (e) {
      dragging = true;
      autoSpin = false;
      last = { x: e.clientX, y: e.clientY };
      host.setPointerCapture(e.pointerId);
    });

    host.addEventListener("pointermove", function (e) {
      if (!dragging) return;
      rotY += (e.clientX - last.x) * 0.4;
      rotX = clamp(rotX - (e.clientY - last.y) * 0.4, -80, 80);
      last = { x: e.clientX, y: e.clientY };
      apply();
    });

    ["pointerup", "pointerleave", "pointercancel"].forEach(function (type) {
      host.addEventListener(type, function () {
        dragging = false;
      });
    });

    host.addEventListener(
      "wheel",
      function (e) {
        e.preventDefault();
        scale = clamp(scale * (e.deltaY < 0 ? 1.08 : 0.93), 0.5, 2.2);
        apply();
      },
      { passive: false }
    );

    function apply() {
      rig.style.transform =
        "rotateX(" + rotX + "deg) rotateY(" + rotY + "deg) scale(" + scale + ")";
    }

    var reduceMotion =
      window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    if (!reduceMotion) {
      requestAnimationFrame(function spin() {
        if (autoSpin && !dragging) {
          rotY += 0.08;
          apply();
        }
        requestAnimationFrame(spin);
      });
    }
  }
})();
