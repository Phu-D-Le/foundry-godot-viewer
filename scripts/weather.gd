extends Node3D
## Foundry's scene weather (Scene Config → Weather) in 3D, from the module's serializeWeather:
##   rain      - thin streaks falling at Foundry's slant (Rain, Rain Storm)
##   snow      - soft flakes drifting sideways (Snow, Blizzard)
##   particles - Foundry's own particle sprites, e.g. its autumn leaves, tumbling down
##   fog       - patchy volumetric fog near the ground, slowly swaying (Fog; also in Rain Storm and Blizzard)
## Particles fall in a box around the camera's look-at point and vanish where they hit something from
## above (a height field of the scene), so roofs and upper floors keep the weather out.
## Unshaded like Foundry's screen-blended weather; leaves are shaded, so they darken at night.

const BOX := 30.0  # meters: half the width of the falling area around the view
const TOP := 22.0  # meters above the look-at point where particles start
const MAX_PARTICLES := 15000
const LEAF_FRAME := 64  # px: each leaf in the particle atlas

var loader: Node  # asset_loader.gd
var post: Node  # post_process.gd: turns volumetric fog on for weather fog
var mpp := 0.003  # meters per Foundry pixel (particle sizes and speeds are in pixels)
## The point weather surrounds (the camera's look-at point), set every frame by main.gd.
var focus := Vector3.ZERO

var _key := ""
var _systems: Array[GPUParticles3D] = []
var _fog: FogVolume
var _height_field: GPUParticlesCollisionHeightField3D
var _scene_size := Vector2(60, 60)
var _fog_home := Vector3.ZERO
var _fog_sway := 0.0  # radians per second (Foundry's fog speed)


func _ready() -> void:
	_height_field = GPUParticlesCollisionHeightField3D.new()
	_height_field.name = "Roofs"
	_height_field.size = Vector3(BOX * 2.0, TOP * 2.0, BOX * 2.0)
	_height_field.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_512
	_height_field.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_WHEN_MOVED
	_height_field.visible = false
	add_child(_height_field)


## Show `weather` (serializeWeather's {id, effects}, or null for none). `scene_size`: the scene in meters.
func apply(weather: Variant, scene_size: Vector2) -> void:
	_scene_size = scene_size
	var key := JSON.stringify(weather) + str(scene_size)
	if key == _key:
		return
	_key = key
	for system in _systems:
		remove_child(system)
		system.queue_free()
	_systems.clear()
	if _fog:
		remove_child(_fog)
		_fog.queue_free()
		_fog = null
	var effects: Array = weather.get("effects", []) if weather is Dictionary else []
	_height_field.visible = not effects.is_empty()
	for effect in effects:
		if not effect is Dictionary:
			continue
		var config: Dictionary = effect.get("config", {})
		match str(effect.get("kind")):
			"rain":
				_add(_rain(config))
			"snow":
				_add(_snow(config))
			"fog":
				_add_fog(config)
			"particles":
				for p in effect.get("particles", []):
					if p is Dictionary:
						_add(await _sprites(p))
	if post:
		post.set_weather_fog(_fog != null)


func _process(_delta: float) -> void:
	for system in _systems:
		system.global_position = focus + Vector3(0.0, TOP, 0.0)
	_height_field.global_position = focus
	if _fog:  # the volume is wider than the scene, so moving it drifts the fog patches over the map
		_fog.position = _fog_home + Vector3(sin(Time.get_ticks_msec() / 1000.0 * _fog_sway) * 8.0, 0.0, 0.0)


func _add(system: GPUParticles3D) -> void:
	if system == null:
		return
	system.local_coords = false  # falling particles stay put while the box follows the view
	system.visibility_aabb = AABB(Vector3(-BOX, -TOP * 2.0, -BOX), Vector3(BOX * 2.0, TOP * 2.5, BOX * 2.0))
	system.position = focus + Vector3(0.0, TOP, 0.0)
	add_child(system)
	_systems.append(system)


## How many particles at `per_m2` over the falling area.
static func _amount(per_m2: float) -> int:
	return clampi(int(per_m2 * BOX * BOX * 4.0), 50, MAX_PARTICLES)


static func _emitter(name_: String, amount: int, lifetime: float) -> Array:
	var system := GPUParticles3D.new()
	system.name = name_
	system.amount = amount
	system.lifetime = lifetime
	system.preprocess = lifetime  # already falling everywhere when it appears
	system.collision_base_size = 0.02
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(BOX, 0.5, BOX)
	process.gravity = Vector3.ZERO
	process.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	system.process_material = process
	return [system, process]


## Foundry's RainShader config: opacity, tint, intensity (amount), rotation (slant, radians), speed.
func _rain(config: Dictionary) -> GPUParticles3D:
	var slant := float(config.get("rotation", 0.26))
	var fall := 18.0 * float(config.get("speed", 0.2)) / 0.2  # m/s
	var parts := _emitter("Rain", _amount(2.5 * float(config.get("intensity", 1.0))), TOP * 1.4 / fall)
	var system: GPUParticles3D = parts[0]
	var process: ParticleProcessMaterial = parts[1]
	process.direction = Vector3(sin(slant), -cos(slant), 0.0)  # wind blows toward +X (east on the map)
	process.spread = 2.0
	process.initial_velocity_min = fall * 0.9
	process.initial_velocity_max = fall * 1.1
	process.particle_flag_align_y = true  # streaks point along their fall
	var tint: Array = config.get("tint", [0.7, 0.9, 1.0])
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(float(tint[0]), float(tint[1]), float(tint[2]), clampf(float(config.get("opacity", 0.25)) * 1.6, 0.05, 1.0))
	mat.vertex_color_use_as_albedo = true
	system.draw_pass_1 = _streak_mesh(0.012, 0.7, mat)
	return system


## Foundry's SnowShader config: tint, direction (sideways drift), speed, scale (flake size).
func _snow(config: Dictionary) -> GPUParticles3D:
	var speed := float(config.get("speed", 2.0))
	var fall := 1.0 + speed * 0.35  # m/s: snow 1.7, blizzard 3.8
	var parts := _emitter("Snow", _amount(0.9 + speed * 0.15), TOP * 1.3 / fall)
	var system: GPUParticles3D = parts[0]
	var process: ParticleProcessMaterial = parts[1]
	var drift := float(config.get("direction", 0.5))
	process.direction = Vector3(drift, -1.0, drift * 0.3).normalized()
	process.spread = 18.0  # flakes drift a little each their own way
	process.initial_velocity_min = fall * 0.8
	process.initial_velocity_max = fall * 1.2
	var size := 0.18 * float(config.get("scale", 2.5)) / 2.5
	process.scale_min = 0.6
	process.scale_max = 1.3
	var tint: Array = config.get("tint", [0.85, 0.95, 1.0])
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_texture = _flake_texture()
	mat.albedo_color = Color(float(tint[0]), float(tint[1]), float(tint[2]), 0.9)
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = mat
	system.draw_pass_1 = quad
	return system


## Foundry particle effects (e.g. autumn leaves): its own sprites, tumbling down. Config in Foundry pixels:
## count (over the screen), lifetime (ms), velocity {speed, angle}, rotation {speed} (deg/s), alpha, scale.
func _sprites(config: Dictionary) -> GPUParticles3D:
	var urls: Array = config.get("textures", [])
	var frames: Array[Image] = []
	for url in urls:
		if url is String and loader:
			var texture: Texture2D = await loader.fetch_texture(url)
			var image: Image = loader.get_image(url) if texture else null
			if image:
				image = image.duplicate()
				image.clear_mipmaps()
				if image.is_compressed():
					image.decompress()
				image.convert(Image.FORMAT_RGBA8)
				image.resize(LEAF_FRAME, LEAF_FRAME)
				frames.append(image)
	if frames.is_empty():
		return null
	var atlas := Image.create(LEAF_FRAME * frames.size(), LEAF_FRAME, false, Image.FORMAT_RGBA8)
	for i in frames.size():
		atlas.blit_rect(frames[i], Rect2i(0, 0, LEAF_FRAME, LEAF_FRAME), Vector2i(i * LEAF_FRAME, 0))
	atlas.generate_mipmaps()
	var velocity: Dictionary = config.get("velocity", {})
	var speeds: Array = velocity.get("speed", [12, 60])
	var angles: Array = velocity.get("angle", [80, 100])
	var spins: Array = config.get("rotation", {}).get("speed", [100, 200])
	var alphas: Array = config.get("alpha", [0.5, 0.9])
	var scales: Array = config.get("scale", [0.1, 0.4])
	var fall := 1.6  # m/s: leaves flutter down slowly
	var per_m2 := float(config.get("count", 200)) / 900.0  # Foundry's count fills about one screen
	var parts := _emitter("Leaves", _amount(per_m2), maxf(float(config.get("lifetime", 10000)) / 1000.0, TOP * 1.2 / fall))
	var system: GPUParticles3D = parts[0]
	var process: ParticleProcessMaterial = parts[1]
	# Foundry's angle is on the map (90 = down the screen = +Z); the leaves also fall.
	var angle := deg_to_rad((float(angles[0]) + float(angles[-1])) / 2.0)
	var drift := (float(speeds[0]) + float(speeds[-1])) / 2.0 * mpp
	process.direction = Vector3(cos(angle) * drift, -fall, sin(angle) * drift).normalized()
	process.spread = absf(float(angles[-1]) - float(angles[0])) / 2.0 + 5.0
	var speed := Vector3(cos(angle) * drift, -fall, sin(angle) * drift).length()
	process.initial_velocity_min = speed * 0.7
	process.initial_velocity_max = speed * 1.3
	process.angular_velocity_min = float(spins[0])
	process.angular_velocity_max = float(spins[-1])
	process.angle_min = 0.0
	process.angle_max = 360.0
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 0.8
	process.turbulence_influence_min = 0.05
	process.turbulence_influence_max = 0.12
	process.scale_min = float(scales[0]) / float(scales[-1])
	process.scale_max = 1.0
	process.anim_offset_min = 0.0
	process.anim_offset_max = 1.0
	var alpha := Gradient.new()  # fade in quickly, out over the last 30 % (Foundry: fade.out 0.3)
	var fade_out: float = 1.0 - float(config.get("fade", {}).get("out", 0.3))
	alpha.set_color(0, Color(1, 1, 1, 0))
	alpha.set_color(1, Color(1, 1, 1, 0))
	alpha.add_point(0.05, Color(1, 1, 1, 1))
	alpha.add_point(clampf(fade_out, 0.06, 0.99), Color(1, 1, 1, 1))
	var ramp := GradientTexture1D.new()
	ramp.gradient = alpha
	process.color_ramp = ramp
	var opacity := (float(alphas[0]) + float(alphas[-1])) / 2.0
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.particles_anim_h_frames = frames.size()
	mat.particles_anim_v_frames = 1
	mat.particles_anim_loop = false
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = ImageTexture.create_from_image(atlas)
	mat.albedo_color = Color(1, 1, 1, opacity)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var quad := QuadMesh.new()
	var leaf_size := clampf(float(scales[-1]) * 400.0 * mpp, 0.15, 0.6)  # Foundry's leaves are ~400 px at scale 1
	quad.size = Vector2(leaf_size, leaf_size)
	quad.material = mat
	system.draw_pass_1 = quad
	return system


## Foundry's FogShader config: intensity (thickness), speed (how fast it drifts; the sign is the direction).
func _add_fog(config: Dictionary) -> void:
	if _fog:  # Rain Storm / Blizzard bring a fog layer; one volume carries the thickest
		var m := _fog.material as FogMaterial
		m.density = maxf(m.density, _fog_density(config))
		return
	_fog = FogVolume.new()
	_fog.name = "WeatherFog"
	_fog.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	var height := 6.0
	_fog.size = Vector3(_scene_size.x + 40.0, height, _scene_size.y + 40.0)
	_fog_home = Vector3(_scene_size.x / 2.0, height / 2.0 - 0.5, _scene_size.y / 2.0)
	_fog.position = _fog_home
	var speed := clampf(float(config.get("speed", 0.4)), -60.0, 60.0)
	_fog_sway = signf(speed) * 0.02 * (0.5 + sqrt(absf(speed)))
	var mat := FogMaterial.new()
	var noise := NoiseTexture3D.new()
	noise.width = 64
	noise.height = 16
	noise.depth = 64
	noise.seamless = true
	var fast := FastNoiseLite.new()
	fast.frequency = 0.08
	noise.noise = fast
	mat.density_texture = noise
	mat.density = _fog_density(config)
	mat.albedo = Color(0.85, 0.88, 0.92)
	mat.emission = Color(0.42, 0.45, 0.5)  # pale mist even in the dark, like Foundry's screen-blended fog
	mat.height_falloff = 0.6  # thick at the ground, thinning upward
	mat.edge_fade = 0.3
	_fog.material = mat
	add_child(_fog)


static func _fog_density(config: Dictionary) -> float:
	return clampf(float(config.get("intensity", 0.4)), 0.0, 2.0) * 0.6


## Two crossed thin quads (visible from every side), Y along the particle's fall.
static func _streak_mesh(width: float, length: float, material: Material) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(material)
	for axis in [Vector3.RIGHT, Vector3.BACK]:
		var w: Vector3 = axis * width / 2.0
		var h := Vector3(0.0, length / 2.0, 0.0)
		var tail := Color(1, 1, 1, 0.0)  # +Y leads the fall; the streak fades toward its tail
		for corner in [[-w - h, tail], [w - h, tail], [w + h, Color.WHITE], [-w - h, tail], [w + h, Color.WHITE], [-w + h, Color.WHITE]]:
			st.set_color(corner[1])
			st.add_vertex(corner[0])
	return st.commit()


static func _flake_texture() -> Texture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 32
	tex.height = 32
	return tex
