/*
 * SPDX-License-Identifier: MIT
 * Author: M. Naufal Alwy
 */

#include "ReShade.fxh"

// Uniform Variables
uniform float FocusSpeed <
    ui_type = "slider";
    ui_min = 0.1; ui_max = 20.0; ui_step = 0.1;
    ui_label = "Focus Speed";
    ui_tooltip = "How fast the autofocus adjusts to depth changes.";
> = 5.0;

uniform float Aperture <
    ui_type = "slider";
    ui_min = 0.1; ui_max = 50.0; ui_step = 0.1;
    ui_label = "Aperture (DoF Strength)";
    ui_tooltip = "Adjusts the strength of the blur effect.";
> = 10.0;

uniform float MaxBlur <
    ui_type = "slider";
    ui_min = 0.001; ui_max = 0.05; ui_step = 0.001;
    ui_label = "Max Blur Radius";
    ui_tooltip = "Maximum blur size in screen space.";
> = 0.02;

uniform float FocusRange <
    ui_type = "slider";
    ui_min = 0.01; ui_max = 0.5; ui_step = 0.01;
    ui_label = "Autofocus Zone Size";
    ui_tooltip = "The radius of the center zone analyzed to find the nearest object.";
> = 0.15;

uniform bool ShowFocusPoint <
    ui_label = "Show Autofocus Zone";
    ui_tooltip = "Displays a rectangle representing the autofocus zone.";
> = false;

uniform bool FullAuto <
    ui_label = "Full Auto Mode (Dynamic DoF)";
    ui_tooltip = "Dynamically adjusts DoF strength based on the focus distance (closer subjects get stronger blur, far landscapes remain sharp).";
> = true;

uniform float ChromaticAberration <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Chromatic Aberration";
    ui_tooltip = "Simulates lens color fringing on blurred edges.";
> = 0.25;

uniform float HighlightBoost <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 10.0; ui_step = 0.1;
    ui_label = "Highlight Boost";
    ui_tooltip = "Boosts the brightness of highlights to create defined bokeh disks.";
> = 2.0;

uniform float HighlightThreshold <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Highlight Threshold";
    ui_tooltip = "Minimum brightness to trigger highlight boost.";
> = 0.8;

uniform float frame_time < source = "frametime"; >;

// Textures & Samplers
texture2D texFocus { Width = 1; Height = 1; Format = R32F; };
sampler2D samFocus { Texture = texFocus; };

// Helper Functions
float GetNoise(float2 co)
{
    return frac(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453);
}

// Compute Focus distance based on the dominant depth (largest object) inside the autofocus zone
void PS_Focus(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float focus : SV_Target)
{
    float currentFocus = tex2D(samFocus, float2(0.5, 0.5)).r;
    if (currentFocus <= 0.0) currentFocus = 1.0;

    // Sample a 5x5 grid in the center zone
    float depths[25];
    int idx = 0;
    
    [unroll]
    for (int x = -2; x <= 2; x++)
    {
        [unroll]
        for (int y = -2; y <= 2; y++)
        {
            float2 offset = float2(x, y) / 2.0 * FocusRange;
            // Correct for aspect ratio
            offset.y *= BUFFER_ASPECT_RATIO;
            float2 sampleCoord = float2(0.5, 0.5) + offset;
            
            depths[idx] = ReShade::GetLinearizedDepth(sampleCoord);
            idx++;
        }
    }

    // Find the depth that has the most similar neighbors (representing the largest object surface)
    float targetFocus = depths[12]; // Default to center sample
    int maxCount = 0;

    for (int i = 0; i < 25; i++)
    {
        int count = 0;
        float d1 = depths[i];
        // Adaptive threshold that scales with depth
        float threshold = 0.01 + d1 * 0.04;
        
        for (int j = 0; j < 25; j++)
        {
            if (abs(d1 - depths[j]) < threshold)
            {
                count++;
            }
        }
        
        // Select depth with the highest frequency. In case of ties, prefer the closer object.
        if (count > maxCount || (count == maxCount && d1 < targetFocus))
        {
            maxCount = count;
            targetFocus = d1;
        }
    }

    // Smoothly interpolate focus
    float factor = saturate(FocusSpeed * (frame_time * 0.001));
    focus = lerp(currentFocus, targetFocus, factor);
}

// Main DoF Blur Pass
void PS_DoF(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 color : SV_Target)
{
    float centerDepth = ReShade::GetLinearizedDepth(texcoord);
    float focusDist = tex2D(samFocus, float2(0.5, 0.5)).r;
    
    float currentAperture = Aperture;
    if (FullAuto)
    {
        currentAperture *= saturate(1.0 - focusDist);
    }

    // Calculate Circle of Confusion (CoC)
    // Foreground (negative CoC) and Background (positive CoC)
    float coc = (centerDepth - focusDist) * currentAperture * 0.01;
    float absCoC = min(abs(coc), MaxBlur);
    
    // If CoC is virtually zero, skip expensive sampling
    if (absCoC < 0.0005)
    {
        color = tex2D(ReShade::BackBuffer, texcoord);
        
        // Show autofocus zone if enabled
        if (ShowFocusPoint)
        {
            float2 dist = abs(texcoord - float2(0.5, 0.5));
            dist.y /= BUFFER_ASPECT_RATIO;
            if (max(dist.x, dist.y) < FocusRange && min(abs(dist.x - FocusRange), abs(dist.y - FocusRange)) < 0.002)
            {
                color.rgb = float3(1.0, 0.0, 0.0);
            }
        }
        return;
    }
    
    // Generate noise for Vogel spiral rotation
    float noise = GetNoise(texcoord + float2(0.0, frame_time * 0.001));
    float angle = noise * 6.2831853;
    float cosAngle = cos(angle);
    float sinAngle = sin(angle);
    float2x2 rotMatrix = float2x2(cosAngle, -sinAngle, sinAngle, cosAngle);
    
    float4 accumColor = 0.0;
    float accumWeight = 0.0;
    
    const int SAMPLES = 16;
    
    for (int i = 0; i < SAMPLES; i++)
    {
        // Vogel Spiral Formula
        float r = sqrt(float(i) + 0.5) / sqrt(float(SAMPLES));
        float theta = float(i) * 2.39996323; // Golden angle in radians
        
        float2 sampleOffset = float2(cos(theta), sin(theta)) * r;
        // Apply random rotation matrix
        sampleOffset = mul(sampleOffset, rotMatrix);
        
        // Scale offset by pixel aspect ratio and maximum CoC
        sampleOffset.x *= absCoC;
        sampleOffset.y *= absCoC * BUFFER_ASPECT_RATIO;
        
        float2 sampleCoords = texcoord + sampleOffset;
        
        // Get sample depth and calculate its own CoC
        float sampleDepth = ReShade::GetLinearizedDepth(sampleCoords);
        float sampleCoC = min(abs((sampleDepth - focusDist) * currentAperture * 0.01), MaxBlur);
        
        // Bleed / Leak prevention
        // A sample should only blur onto the center pixel if:
        // 1. It is in the foreground (relative to the center) and its own blur radius is large enough to reach.
        // 2. Or the center pixel itself is blurred (background DoF).
        float weight = 1.0;
        if (sampleDepth < centerDepth)
        {
            // Sample is in front of center pixel
            weight = saturate(sampleCoC / (length(sampleOffset) + 0.0001));
        }
        else
        {
            // Sample is behind center pixel
            weight = saturate(absCoC / (length(sampleOffset) + 0.0001));
        }
        
        // Chromatic Aberration: shift UVs per channel based on local CoC
        float2 caOffset = sampleOffset * ChromaticAberration * 0.15;
        float rCol = tex2D(ReShade::BackBuffer, sampleCoords + caOffset).r;
        float gCol = tex2D(ReShade::BackBuffer, sampleCoords).g;
        float bCol = tex2D(ReShade::BackBuffer, sampleCoords - caOffset).b;
        float3 sampleColor = float3(rCol, gCol, bCol);
        
        // Highlight Boost (Bokeh Highlights)
        float luma = dot(sampleColor, float3(0.299, 0.587, 0.114));
        float highlight = max(0.0, luma - HighlightThreshold);
        float boost = 1.0 + highlight * HighlightBoost;
        
        accumColor += float4(sampleColor * boost, 1.0) * weight;
        accumWeight += weight;
    }
    
    if (accumWeight > 0.0001)
    {
        color = accumColor / accumWeight;
    }
    else
    {
        color = tex2D(ReShade::BackBuffer, texcoord);
    }
    
    // Show autofocus zone if enabled
    if (ShowFocusPoint)
    {
        float2 dist = abs(texcoord - float2(0.5, 0.5));
        dist.y /= BUFFER_ASPECT_RATIO;
        if (max(dist.x, dist.y) < FocusRange && min(abs(dist.x - FocusRange), abs(dist.y - FocusRange)) < 0.002)
        {
            color.rgb = float3(1.0, 0.0, 0.0);
        }
    }
}

// Techniques
technique CinematicDoF
{
    pass PassFocus
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Focus;
        RenderTarget = texFocus;
    }
    pass PassDoF
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_DoF;
    }
}
