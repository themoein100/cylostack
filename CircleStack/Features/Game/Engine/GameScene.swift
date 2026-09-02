//
//  GameScene.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SpriteKit
import UIKit

class GameScene: SKScene {

    weak var gameDelegate: GameSceneDelegate?

    // Config properties (updated by game controller)
    var currentMaterial: DiscMaterial = DiscMaterial.all[0]
    var difficulty: DifficultySettings = DifficultySettings(speedLevel: 3, shrinkLevel: 3)
    var currentBg: BgTheme = GameConfig.backgrounds[0] {
        didSet {
            guard view != nil, currentBg != oldValue else { return }
            updateBackdrop()
        }
    }

    // Core game nodes
    let cameraNode = SKCameraNode()
    let towerNode = SKNode() // Holds stacked discs
    let debrisNode = SKNode() // Holds sliced-off pieces
    private var activeDisc: CylinderNode?
    private var towerDiscs: [CylinderNode] = []

    // Gameplay states
    private var score = 0
    private var scoreOffsetForSpeed = 0
    private var combo = 0
    private var isPlaying = false
    private var isGameOver = false

    // Sweeping state. The incoming disc slides along one ground axis at a time,
    // `sweepOffset` from the centre of the disc it will land on.
    private var sweepAxis: CGPoint = GameConfig.sweepAxes[0]
    private var sweepCenter: CGPoint = .zero
    private var sweepOffset: CGFloat = 0.0
    private var sweepDirection: CGFloat = 1.0
    private var sweepSpeed: CGFloat = 200.0
    private var currentDiscWidth: CGFloat = GameConfig.baseWidth

    // Colour state: the hue the run starts on, every disc steps on from there
    private var baseHue: CGFloat = 0.0
    // Seeded from PlayerStore so GameScene and the menu always agree on the hue.
    private var lastRunHue: CGFloat = PlayerStore.shared.lastRunHue

    // Camera follow state
    private var targetCameraY: CGFloat = 0.0
    private var targetCameraX: CGFloat = 0.0
    private var targetCameraScale: CGFloat = GameConfig.gameZoom
    private var lastUpdateTime: TimeInterval = 0.0
    private var lastPlacementTime: TimeInterval = 0.0

    // Layout
    private let towerBaseY: CGFloat = 150.0

    // Backdrop
    private var backgroundNode: SKSpriteNode?
    private var towerGlowNode: SKSpriteNode?
    private var starNodes: [SKSpriteNode] = []
    private var orbNodes: [SKSpriteNode] = []

    // Cached textures
    private var cachedParticleTexture: SKTexture?
    private var cachedGlowTexture: SKTexture?

    override func didMove(to view: SKView) {
        Logger.shared.i("GameScene", "didMove loaded. Material: \(currentMaterial.name), Bg: \(currentBg.name)")
        // Setup camera
        camera = cameraNode
        if cameraNode.parent == nil {
            addChild(cameraNode)
        }
        cameraNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        targetCameraY = size.height / 2
        targetCameraX = size.width / 2

        // Gravity only ever acts on sliced-off debris. This is in m/s² and SpriteKit
        // converts at 150 points per metre, so -9.0 lands at -1350 pt/s²: a piece cut
        // off the stack top clears the frame in a little under a second. Velocities on
        // the bodies below are plain points per second, so the two do not match units.
        physicsWorld.gravity = CGVector(dx: 0, dy: -9.0)

        if backgroundNode == nil {
            setupBackdrop()
        }

        // Setup tower base
        towerNode.position = CGPoint(x: size.width / 2, y: towerBaseY)
        if towerNode.parent == nil {
            addChild(towerNode)
        }

        // Sliced pieces always render in front of the stack
        debrisNode.zPosition = 90_000.0
        if debrisNode.parent == nil {
            addChild(debrisNode)
        }

        // Load initial game state only if not already prepared
        if towerDiscs.isEmpty {
            prepareStack()
        } else {
            updateBackdrop()
        }
    }

    // MARK: - Backdrop

    private func setupBackdrop() {
        backgroundNode?.removeFromParent()
        towerGlowNode?.removeFromParent()

        // Gradient pinned to the camera so it covers the frame at any zoom
        let bg = SKSpriteNode()
        bg.size = CGSize(width: size.width * 3.0, height: size.height * 3.0)
        bg.zPosition = -1000.0
        cameraNode.addChild(bg)
        backgroundNode = bg

        // Soft neon bloom sitting behind the action, tinted like the top disc
        let glow = SKSpriteNode(texture: radialGlowTexture())
        glow.size = CGSize(width: size.width * 1.9, height: size.width * 1.9)
        glow.position = CGPoint(x: 0, y: -40)
        glow.zPosition = -999.0
        glow.blendMode = .add
        glow.colorBlendFactor = 1.0
        glow.alpha = 0.46
        cameraNode.addChild(glow)
        towerGlowNode = glow

        setupDecor()
        updateBackdrop()
    }

    /// Drifting neon dust and a few soft blooms behind the stack. All of it hangs off
    /// the camera, so it stays in frame however far the tower climbs, and all of it
    /// is additive and dim enough never to compete with the discs.
    private func setupDecor() {
        (starNodes + orbNodes).forEach { $0.removeFromParent() }
        starNodes.removeAll()
        orbNodes.removeAll()

        let spanX = size.width * 1.6
        let spanY = size.height * 1.6

        for _ in 0..<3 {
            let orb = SKSpriteNode(texture: radialGlowTexture())
            let diameter = CGFloat.random(in: size.width * 0.5...size.width * 0.95)
            orb.size = CGSize(width: diameter, height: diameter)
            orb.position = CGPoint(x: .random(in: -spanX / 2...spanX / 2),
                                   y: .random(in: -spanY / 2...spanY / 2))
            orb.zPosition = -990.0
            orb.blendMode = .add
            orb.colorBlendFactor = 1.0
            orb.alpha = CGFloat.random(in: 0.05...0.10)
            cameraNode.addChild(orb)
            orbNodes.append(orb)

            let travel = CGFloat.random(in: 40.0...90.0)
            let period = Double.random(in: 9.0...16.0)
            let wander = SKAction.sequence([
                .moveBy(x: travel, y: travel * 0.6, duration: period),
                .moveBy(x: -travel, y: -travel * 0.6, duration: period)
            ])
            wander.timingMode = .easeInEaseOut
            orb.run(SKAction.repeatForever(wander))
        }

        for _ in 0..<46 {
            let dot = SKSpriteNode(texture: createParticleTexture())
            let diameter = CGFloat.random(in: 3.0...9.0)
            dot.size = CGSize(width: diameter, height: diameter)
            dot.position = CGPoint(x: .random(in: -spanX / 2...spanX / 2),
                                   y: .random(in: -spanY / 2...spanY / 2))
            dot.zPosition = -960.0
            dot.blendMode = SKBlendMode.add
            dot.colorBlendFactor = 1.0
            cameraNode.addChild(dot)
            starNodes.append(dot)

            // Small dots sit further back, so they drift slower and burn dimmer
            let depth = (diameter - 3.0) / 6.0
            let peak = 0.16 + 0.34 * depth
            dot.alpha = peak

            let rise = 18.0 + 34.0 * depth
            let period = Double.random(in: 5.0...11.0)
            let drift = SKAction.sequence([
                .moveBy(x: 0, y: rise, duration: period),
                .moveBy(x: 0, y: -rise, duration: period)
            ])
            drift.timingMode = .easeInEaseOut
            dot.run(SKAction.repeatForever(drift))

            let twinkle = SKAction.sequence([
                .fadeAlpha(to: peak * 0.2, duration: Double.random(in: 1.1...2.8)),
                .fadeAlpha(to: peak, duration: Double.random(in: 1.1...2.8))
            ])
            dot.run(SKAction.repeatForever(twinkle))
        }
    }

    /// Re-tints the backdrop to the colour currently on top of the stack.
    private func updateBackdrop() {
        let palette = paletteForTopDisc()
        let colors = NeonPalette.backdrop(hue: palette.hue, base: currentBg)

        backgroundNode?.texture = verticalGradientTexture(top: colors.top, bottom: colors.bottom)
        
        let colorAction = SKAction.colorize(with: palette.glow, colorBlendFactor: 1.0, duration: 0.35)
        towerGlowNode?.run(colorAction)
        backgroundColor = colors.bottom

        // Pull the decor along the wheel with the stack, smoothly harmonizing colors
        for (index, orb) in orbNodes.enumerated() {
            let accentColor = NeonPalette.accent(hue: palette.hue, shift: 0.16 + 0.17 * CGFloat(index))
            orb.run(.colorize(with: accentColor, colorBlendFactor: 1.0, duration: 0.35))
        }
        for (index, dot) in starNodes.enumerated() {
            let dotColor = index % 3 == 0
                ? NeonPalette.accent(hue: palette.hue, shift: 0.42)
                : palette.glow
            dot.run(.colorize(with: dotColor, colorBlendFactor: 1.0, duration: 0.35))
        }
    }

    /// The backdrop always follows the run hue, never the material. A wooden run
    /// still deserves a sky of its own instead of the same brown every time.
    private func paletteForTopDisc() -> DiscPalette {
        NeonPalette.palette(index: max(0, towerDiscs.count - 1), baseHue: baseHue)
    }

    private func verticalGradientTexture(top: SKColor, bottom: SKColor) -> SKTexture {
        let texSize = CGSize(width: 4, height: 256)
        let renderer = UIGraphicsImageRenderer(size: texSize)
        let image = renderer.image { ctx in
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
                ctx.cgContext.drawLinearGradient(gradient,
                                                 start: .zero,
                                                 end: CGPoint(x: 0, y: texSize.height),
                                                 options: [])
            }
        }
        return SKTexture(image: image)
    }

    private func radialGlowTexture() -> SKTexture {
        if let cached = cachedGlowTexture { return cached }
        let texSize = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: texSize)
        let image = renderer.image { ctx in
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [UIColor.white.withAlphaComponent(0.85).cgColor,
                          UIColor.white.withAlphaComponent(0.22).cgColor,
                          UIColor.white.withAlphaComponent(0.0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.45, 1.0]) {
                let center = CGPoint(x: texSize.width / 2, y: texSize.height / 2)
                ctx.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                                 endCenter: center, endRadius: texSize.width / 2, options: [])
            }
        }
        let texture = SKTexture(image: image)
        cachedGlowTexture = texture
        return texture
    }

    // MARK: - Run lifecycle

    /// The colour every run opens on. Each one jumps at least a third of the way
    /// around the wheel from the last, so two runs back to back never start on
    /// near-identical shades — a random hue on its own repeats itself too often to
    /// feel deliberate.
    /// Advances to the next run colour and commits it to PlayerStore so the menu
    /// preview and start button immediately reflect what the upcoming game will look like.
    /// Call this when LEAVING a game (reset / quit / game-over), never when starting one.
    private func nextRunHue() -> CGFloat {
        let jump = CGFloat.random(in: 0.3...0.7)
        lastRunHue = (lastRunHue + jump).truncatingRemainder(dividingBy: 1.0)
        PlayerStore.shared.lastRunHue = lastRunHue
        return lastRunHue
    }

    /// Public entry point for the ViewModel to advance the hue before a replay,
    /// so the game-over → replay path also gets a fresh colour shown on screen.
    func advanceRunHue() {
        _ = nextRunHue()
    }

    /// Rolls the run's colour and rebuilds the stack, without starting play.
    ///
    /// This is deliberately separate from `startGame`: the scene has to already be
    /// the right colour on the frame it becomes visible. Rolling the hue after the
    /// view is on screen is what used to make a run open blue and then snap to its
    /// real colour a moment later.
    func prepareRun() {
        prepareStack()
    }

    func startGame() {
        Logger.shared.i("GameScene", "startGame — beginning sweep")
        isPlaying = true
        // 300ms grace period on startup so tapping the menu's START button never triggers an instant disc drop
        lastPlacementTime = CACurrentMediaTime() + 0.30

        spawnNextDisc()
        gameDelegate?.gameDidUpdateScore(score: 0, combo: 0)
    }

    func resetGame() {
        // Pick the NEXT run's colour and commit it to PlayerStore before rebuilding
        // the stack, so the menu preview is always ahead by one and matches Start.
        _ = nextRunHue()
        prepareStack()
    }

    /// Tears down the previous run and rebuilds the single base disc.
    private func prepareStack() {
        removeAllActions()
        isPlaying = false
        isGameOver = false
        score = 0
        scoreOffsetForSpeed = 0
        combo = 0
        currentDiscWidth = GameConfig.baseWidth
        lastUpdateTime = 0.0
        // Consume the hue already committed to PlayerStore by nextRunHue() — do NOT
        // call nextRunHue() here or a second random jump would overwrite what the
        // menu is already showing the player.
        baseHue = PlayerStore.shared.lastRunHue
        lastRunHue = baseHue

        activeDisc?.removeFromParent()
        activeDisc = nil

        towerNode.removeAllChildren()
        towerDiscs.removeAll()
        debrisNode.removeAllChildren()
        towerNode.position = CGPoint(x: size.width / 2, y: towerBaseY)
        towerNode.zRotation = 0.0

        // Center camera and reset zoom (Zoom out slightly to move game away from player)
        cameraNode.removeAllActions()
        cameraNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraNode.setScale(GameConfig.gameZoom)
        targetCameraY = size.height / 2
        targetCameraX = size.width / 2
        targetCameraScale = GameConfig.gameZoom

        // Build base disc
        let baseDisc = CylinderNode(width: currentDiscWidth,
                                    material: currentMaterial,
                                    palette: NeonPalette.palette(index: 0, baseHue: baseHue, material: currentMaterial))
        baseDisc.ground = .zero
        baseDisc.position = towerLocalPosition(ground: .zero, level: 0)
        baseDisc.zPosition = 0.0
        towerNode.addChild(baseDisc)
        towerDiscs.append(baseDisc)

        updateBackdrop()
    }

    /// Where a disc standing at `ground` on level `level` sits inside the tower.
    private func towerLocalPosition(ground: CGPoint, level: Int) -> CGPoint {
        let iso = GameConfig.screenOffset(ground: ground)
        return CGPoint(x: iso.x, y: CGFloat(level) * GameConfig.baseThickness + iso.y)
    }

    /// Ground position of the incoming disc when it is `offset` along the sweep axis.
    private func sweptGround(_ offset: CGFloat) -> CGPoint {
        CGPoint(x: sweepCenter.x + sweepAxis.x * offset,
                y: sweepCenter.y + sweepAxis.y * offset)
    }

    private func spawnNextDisc() {
        guard let lastDisc = towerDiscs.last else { return }
        let level = towerDiscs.count

        // Swap to the other ground axis on every disc, and come in off the opposite
        // end every other pair, so the approach never settles into one groove.
        sweepAxis = GameConfig.sweepAxes[level % GameConfig.sweepAxes.count]
        sweepCenter = lastDisc.ground
        let entrySide: CGFloat = (level % 4 < 2) ? 1.0 : -1.0
        sweepOffset = entrySide * GameConfig.sweepRange
        sweepDirection = -entrySide

        let disc = CylinderNode(width: currentDiscWidth,
                                material: currentMaterial,
                                palette: NeonPalette.palette(index: level, baseHue: baseHue, material: currentMaterial))
        disc.ground = sweptGround(sweepOffset)
        disc.position = towerNode.convert(towerLocalPosition(ground: disc.ground, level: level), to: self)
        disc.zPosition = 50_000.0 // above the whole stack while it sweeps
        addChild(disc) // Lives in scene space, independent of the tower
        activeDisc = disc

        // Speed up gradually as the stack grows
        let effectiveScore = max(0, score - scoreOffsetForSpeed)
        let speed = difficulty.startSweepSpeed * (1.0 + CGFloat(effectiveScore) * difficulty.sweepSpeedGrowth)
        sweepSpeed = min(speed, difficulty.maxSweepSpeed)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        placeActiveDiscFromPrimaryInput()
    }

    /// Shared by touch, UIKit key commands, and SpriteKit keyboard input. Keeping the
    /// debounce here makes Space behave exactly like a mouse or screen tap.
    func placeActiveDiscFromPrimaryInput() {
        guard isPlaying && !isGameOver else { return }
        let now = CACurrentMediaTime()
        guard now >= lastPlacementTime else { return }
        lastPlacementTime = now + 0.18
        placeActiveDisc()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.key?.keyCode == .keyboardSpacebar || press.key?.characters == " " {
                placeActiveDiscFromPrimaryInput()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: - Placement (the core Stack rule)

    private func placeActiveDisc() {
        guard let active = activeDisc, let last = towerDiscs.last else { return }
        activeDisc = nil

        let level = towerDiscs.count
        let offset = sweepOffset           // signed miss, measured along the sweep axis
        let absOffset = abs(offset)
        let direction: CGFloat = offset >= 0 ? 1.0 : -1.0

        // Largest disc that still fits inside the overlap of the two circles:
        // for radii r1, r2 whose centers are |offset| apart it is (r1 + r2 - |offset|).
        let movingWidth = active.width
        let supportWidth = last.width
        // A miss costs `absOffset` of width at Normal; the difficulty dial scales
        // how much of that bite actually lands.
        let bite = absOffset * difficulty.shrinkFactor
        let keptWidth = min(movingWidth, supportWidth, (movingWidth + supportWidth) / 2.0 - bite)

        if keptWidth <= GameConfig.minDiscWidth {
            Logger.shared.i("GameScene", "MISS! Overlap \(keptWidth) too small to stand on. Game over.")
            finishWithMiss(disc: active, direction: direction)
            return
        }

        let isPerfect = absOffset <= GameConfig.perfectTolerance
        score += 1

        // Move the disc into the tower hierarchy at its landing spot
        let palette = active.palette
        active.removeFromParent()
        active.zPosition = CGFloat(level) * 10.0
        towerNode.addChild(active)
        towerDiscs.append(active)

        if isPerfect {
            combo += 1
            Logger.shared.d("GameScene", "PERFECT hit! Snapping center. Combo: \(combo)")

            // Snap dead-center, keep the full width, and start growing back on a streak
            active.ground = last.ground
            currentDiscWidth = combo >= GameConfig.perfectRegrowCombo
                ? min(GameConfig.baseWidth, movingWidth + GameConfig.perfectRegrowAmount)
                : movingWidth

            active.position = towerLocalPosition(ground: active.ground, level: level)
            active.playLandingHalo(color: palette.glow, strength: 1.0, rings: min(combo, 3))
            spawnPerfectParticles(atLocal: active.position, width: movingWidth, color: palette.glow)
            SoundManager.shared.playPerfect()
            gameDelegate?.gameDidPerfectHit(combo: combo)
        } else {
            combo = 0
            Logger.shared.d("GameScene", "TRIMMED! Offset: \(offset), kept width: \(keptWidth)")

            // The disc keeps only the part that had something under it, so it shrinks
            // and slides back toward the disc below. Nothing breaks away — the
            // overhang is simply gone, and the flash and sparks carry the moment.
            let pullBack = direction * (movingWidth - keptWidth) / 2.0
            active.ground = CGPoint(x: active.ground.x - sweepAxis.x * pullBack,
                                    y: active.ground.y - sweepAxis.y * pullBack)
            active.updateWidth(keptWidth)
            currentDiscWidth = keptWidth
            active.position = towerLocalPosition(ground: active.ground, level: level)

            // Sell the cut on the disc that stayed: a hot edge, then the halo
            active.flashCutEdge()
            active.playLandingHalo(color: palette.glow, strength: 0.45)
            spawnCutSparks(atGround: last.ground, level: level,
                           axisDirection: direction, reach: supportWidth / 2.0,
                           color: palette.glow)

            if absOffset > GameConfig.goodTolerance {
                SoundManager.shared.playBad()
            } else {
                SoundManager.shared.playGood()
            }
        }

        active.playLandingSquash()
        updateBackdrop()
        updateCameraTarget()
        gameDelegate?.gameDidUpdateScore(score: score, combo: combo)
        spawnNextDisc()
    }

    /// Burst of sparks off the rim the disc was trimmed against, thrown outward along
    /// whichever ground axis the disc came in on.
    private func spawnCutSparks(atGround ground: CGPoint, level: Int,
                                axisDirection: CGFloat, reach: CGFloat, color: SKColor) {
        let rimGround = CGPoint(x: ground.x + sweepAxis.x * axisDirection * reach,
                                y: ground.y + sweepAxis.y * axisDirection * reach)
        let position = towerNode.convert(towerLocalPosition(ground: rimGround, level: level), to: self)

        // Point the burst the way the trimmed-off part was sticking out, on screen
        let outward = GameConfig.screenOffset(ground: CGPoint(x: sweepAxis.x * axisDirection,
                                                              y: sweepAxis.y * axisDirection))

        let emitter = SKEmitterNode()
        emitter.particleTexture = createParticleTexture()
        emitter.particleColorSequence = nil
        emitter.particleColor = color
        emitter.particleColorBlendFactor = 1.0
        emitter.particleBlendMode = .add
        emitter.position = position
        emitter.zPosition = 95_000.0

        emitter.numParticlesToEmit = 18
        emitter.particleBirthRate = 600
        emitter.particleLifetime = 0.32
        emitter.particleLifetimeRange = 0.12
        emitter.particleSpeed = 210
        emitter.particleSpeedRange = 90
        emitter.emissionAngle = atan2(outward.y, outward.x)
        emitter.emissionAngleRange = 1.1
        emitter.yAcceleration = -420
        emitter.particleScale = 0.13
        emitter.particleScaleRange = 0.06
        emitter.particleScaleSpeed = -0.28
        emitter.particleAlphaSpeed = -2.4

        addChild(emitter)
        emitter.run(.sequence([.wait(forDuration: 0.7), .removeFromParent()]))
    }

    // MARK: - Game over

    private func finishWithMiss(disc: CylinderNode, direction: CGFloat) {
        isPlaying = false
        isGameOver = true

        // Hand the disc to the debris layer at the exact spot it was released
        let worldPos = disc.position // already scene space
        disc.removeFromParent()
        disc.position = worldPos
        disc.zPosition = 0.0
        debrisNode.addChild(disc)

        // Send it off the way it was already heading, along its own ground axis
        let outward = GameConfig.screenOffset(ground: CGPoint(x: sweepAxis.x * direction,
                                                              y: sweepAxis.y * direction))
        let length = max(0.001, hypot(outward.x, outward.y))
        disc.attachFallingBody(velocity: CGVector(dx: outward.x / length * 190.0,
                                                  dy: outward.y / length * 90.0),
                               spin: outward.x >= 0 ? -2.6 : 2.6)
        disc.run(.sequence([.wait(forDuration: 2.5), .removeFromParent()]))

        SoundManager.shared.playFall()
        shakeCamera(intensity: 3.5, duration: 0.18)

        run(.sequence([
            .wait(forDuration: 0.35),
            .run { [weak self] in self?.showcaseTower() },
            .wait(forDuration: 1.05),
            .run { [weak self] in
                guard let self = self else { return }
                self.gameDelegate?.gameDidGameOver(finalScore: self.score)
            }
        ]))
    }

    enum ReviveType {
        case adOne   // 1st Ad Revive: +60% enlargement (was +33.3%)
        case adTwo   // 2nd Ad Revive: +100% (double) enlargement (was +66.7%)
        case coins   // 2 Coins Revive: 2.2x if very small (<50% baseWidth), else +100% (double)
    }

    /// Revives the player run, enlarging the top disc on the tower to give a wide base target
    func reviveGame(reviveType: ReviveType = .adOne) {
        guard isGameOver else { return }
        removeAllActions()
        activeDisc?.removeFromParent()
        activeDisc = nil
        
        isGameOver = false
        isPlaying = true
        
        // Reset speed progression so it starts slower from the beginning speed level again
        scoreOffsetForSpeed = score

        let topDiscWidth = towerDiscs.last?.width ?? GameConfig.baseWidth
        let expandedWidth: CGFloat

        switch reviveType {
        case .adOne:
            expandedWidth = min(GameConfig.baseWidth, topDiscWidth * 1.6)
        case .adTwo:
            expandedWidth = min(GameConfig.baseWidth, topDiscWidth * 2.0)
        case .coins:
            let isVerySmall = topDiscWidth < (GameConfig.baseWidth * 0.50)
            let scaleFactor: CGFloat = isVerySmall ? 2.2 : 2.0
            expandedWidth = min(GameConfig.baseWidth, topDiscWidth * scaleFactor)
        }

        currentDiscWidth = expandedWidth

        // 2. Replace top disc on tower with the enlarged disc
        if !towerDiscs.isEmpty {
            let level = towerDiscs.count - 1
            let lastDisc = towerDiscs[level]
            let ground = lastDisc.ground
            let pos = lastDisc.position
            lastDisc.removeFromParent()

            let expandedDisc = CylinderNode(width: expandedWidth,
                                            material: currentMaterial,
                                            palette: NeonPalette.palette(index: level, baseHue: baseHue, material: currentMaterial))
            expandedDisc.ground = ground
            expandedDisc.position = pos
            expandedDisc.zPosition = CGFloat(level) * 10.0
            towerNode.addChild(expandedDisc)
            towerDiscs[level] = expandedDisc

            // Play landing squash and halo pulse on the enlarged disc for awesome visual feedback
            expandedDisc.playLandingSquash()
            expandedDisc.playLandingHalo(color: paletteForTopDisc().glow, strength: 1.0, rings: 2)
        }

        // 3. Animate camera back to top of tower
        updateCameraTarget()
        cameraNode.removeAllActions()
        let move = SKAction.move(to: CGPoint(x: targetCameraX, y: targetCameraY), duration: 0.6)
        let zoom = SKAction.scale(to: targetCameraScale, duration: 0.6)
        move.timingMode = .easeOut
        zoom.timingMode = .easeOut
        cameraNode.run(.group([move, zoom])) { [weak self] in
            self?.spawnNextDisc()
        }
    }

    /// Pulls the camera back to show what was built. Very tall stacks are framed
    /// from the top instead of being shrunk into an unreadable sliver.
    private func showcaseTower() {
        cameraNode.removeAllActions()
        guard let top = towerDiscs.last else { return }

        let topWorld = towerNode.convert(top.position, to: self)
        let towerHeight = topWorld.y - towerBaseY + GameConfig.baseThickness

        // Only pull back if the stack does not already fit. A short stack is framed
        // at the same distance it was played at — backing off further just shrinks it
        // for no reason.
        let padding: CGFloat = 120.0
        let fitScale = (towerHeight + padding) / size.height
        let fitsOnScreen = fitScale <= GameConfig.maxShowcaseZoom
        let targetScale = min(max(cameraNode.xScale, fitScale), GameConfig.maxShowcaseZoom)
        let visibleHeight = size.height * targetScale

        // Nudge the stack down a touch, but no further: the game-over card is glass,
        // so a stack sitting behind it shows through rather than being swallowed.
        let lowered = visibleHeight * 0.05
        let targetY = fitsOnScreen
            ? max(size.height / 2.0, towerBaseY + towerHeight / 2.0) + lowered
            : topWorld.y - visibleHeight * 0.28 + lowered

        // Horizontal midpoint of everything the stack drifted across
        let xs = towerDiscs.map { towerNode.convert($0.position, to: self).x }
        let targetX = ((xs.min() ?? size.width / 2) + (xs.max() ?? size.width / 2)) / 2.0

        let move = SKAction.move(to: CGPoint(x: targetX, y: targetY), duration: 0.9)
        let zoom = SKAction.scale(to: targetScale, duration: 0.9)
        move.timingMode = .easeInEaseOut
        zoom.timingMode = .easeInEaseOut
        cameraNode.run(.group([move, zoom]))
    }

    // MARK: - Camera

    private func updateCameraTarget() {
        guard let top = towerDiscs.last else { return }
        let topWorld = towerNode.convert(top.position, to: self)
        targetCameraY = max(size.height / 2.0, topWorld.y + 130.0)

        // Only chase part of the sideways drift. Matching it outright makes the whole
        // frame jerk sideways on every placement, because each disc arrives on the
        // axis perpendicular to the one before it — the camera ends up shaking left
        // and right in step with the stack instead of quietly rising with it.
        let centre = size.width / 2.0
        targetCameraX = centre + (topWorld.x - centre) * 0.4

        // Ease the view open as the stack grows, so the climb stays comfortable
        targetCameraScale = min(GameConfig.gameZoom + CGFloat(score) * GameConfig.zoomGrowth,
                                GameConfig.maxGameZoom)
    }

    // MARK: - Core game loop

    override func update(_ currentTime: TimeInterval) {
        // Real delta time: the sweep must run at the same speed on 60Hz and 120Hz
        var dt = currentTime - lastUpdateTime
        lastUpdateTime = currentTime
        if dt <= 0 || dt > 0.05 { dt = 1.0 / 60.0 } // first frame / hitch guard

        guard isPlaying && !isGameOver else { return }

        // 1. Slide the active disc back and forth along its ground axis
        if let active = activeDisc {
            let limit = GameConfig.sweepRange
            var next = sweepOffset + sweepSpeed * CGFloat(dt) * sweepDirection

            // Reflect off the bounds instead of clamping, so the disc can never stick
            if next > limit {
                next = limit - (next - limit)
                sweepDirection = -1.0
            } else if next < -limit {
                next = -limit + (-limit - next)
                sweepDirection = 1.0
            }
            sweepOffset = next
            active.ground = sweptGround(sweepOffset)
            active.position = towerNode.convert(
                towerLocalPosition(ground: active.ground, level: towerDiscs.count), to: self)
        }

        // 2. Smooth, frame-rate independent camera follow. Rising has to keep up with
        //    the stack, but drifting sideways is pure presentation — settling it much
        //    more slowly is what keeps the frame calm.
        let rise = CGFloat(1.0 - pow(0.12, dt))
        let drift = CGFloat(1.0 - pow(0.45, dt))
        cameraNode.position.x += (targetCameraX - cameraNode.position.x) * drift
        cameraNode.position.y += (targetCameraY - cameraNode.position.y) * rise
        cameraNode.setScale(cameraNode.xScale + (targetCameraScale - cameraNode.xScale) * rise)
    }
}
