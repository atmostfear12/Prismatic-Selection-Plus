#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:globals.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <minecraft:projection.glsl>

in vec3 Position;
in vec4 Color;
in vec3 Normal;
in float LineWidth;

out float sphericalVertexDistance;
out float cylindricalVertexDistance;
out vec4 vertexColor;

vec3 hsvToRgb(vec3 hsv) {
    vec3 p = abs(fract(hsv.xxx + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    vec3 rgb = clamp(p - 1.0, 0.0, 1.0);
    rgb = rgb * rgb * (3.0 - 2.0 * rgb);
    return hsv.z * mix(vec3(1.0), rgb, hsv.y);
}

bool isSelectionOutline(vec4 c) {
    float brightest = max(c.r, max(c.g, c.b));
    return brightest < 0.03 && c.a > 0.34 && c.a < 0.46;
}

void main() {
    vec4 startView = ModelViewMat * vec4(Position, 1.0);
    vec4 endView = ModelViewMat * vec4(Position + Normal, 1.0);
    const float shrink = 255.0 / 256.0;
    startView.xyz *= shrink;
    endView.xyz *= shrink;

    vec4 startClip = ProjMat * startView;
    vec4 endClip = ProjMat * endView;

    vec3 startNdc = startClip.xyz / startClip.w;
    vec3 endNdc = endClip.xyz / endClip.w;

    vec2 pixelDirection = (endNdc.xy - startNdc.xy) * ScreenSize;
    float directionLength = max(length(pixelDirection), 0.00001);
    vec2 unitDirection = pixelDirection / directionLength;
    vec2 perpendicular = vec2(-unitDirection.y, unitDirection.x);
    vec2 offset = perpendicular * (LineWidth / ScreenSize);

    if (offset.x < 0.0) offset = -offset;

    float side = (gl_VertexID % 2 == 0) ? 1.0 : -1.0;
    vec3 expanded = startNdc + vec3(offset * side, 0.0);
    gl_Position = vec4(expanded * startClip.w, startClip.w);

    sphericalVertexDistance = fog_spherical_distance(Position);
    cylindricalVertexDistance = fog_cylindrical_distance(Position);

    if (isSelectionOutline(Color)) {
        float hue = fract(GameTime * 480.0 + dot(Position, vec3(0.013, 0.021, 0.017)));
        vertexColor = vec4(hsvToRgb(vec3(hue, 0.88, 1.0)), 1.0);
    } else {
        vertexColor = Color;
    }
}
