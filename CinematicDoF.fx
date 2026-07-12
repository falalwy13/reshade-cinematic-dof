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
    ui_label = "Show DSLR AF Points";
    ui_tooltip = "Displays the DSLR autofocus points. Active points are green, inactive points are red/grey.";
> = false;

uniform int FocusPointSelect <
    ui_type = "combo";
    ui_label = "AF Point Selection";
    ui_items = "Auto (5-Point)\0Center\0Left\0Right\0Top\0Bottom\0";
    ui_tooltip = "Selects which DSLR focus point to use. Auto will choose the closest target among all 5 points.";
> = 0;

uniform float FocusPointOffset <
    ui_type = "slider";
    ui_min = 0.05; ui_max = 0.4; ui_step = 0.01;
    ui_label = "AF Point Offset";
    ui_tooltip = "Distance of the Left, Right, Top, and Bottom points from the center.";
> = 0.15;

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
texture2D texFocus { Width = 1; Height = 1; Format = RG32F; };
sampler2D samFocus { Texture = texFocus; };

// Helper Functions
float GetNoise(float2 co)
{
    return frac(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453);
}

float GetPointFocusDepth(float2 centerCoord)
{
    float depths[9];
    int idx = 0;
    
    [unroll]
    for (int x = -1; x <= 1; x++)
    {
        [unroll]
        for (int y = -1; y <= 1; y++)
        {
            float2 offset = float2(x, y) * (FocusRange * 0.5);
            // Correct for aspect ratio
            offset.y *= BUFFER_ASPECT_RATIO;
            float2 sampleCoord = centerCoord + offset;
            sampleCoord = clamp(sampleCoord, 0.0, 1.0);
            
            depths[idx] = ReShade::GetLinearizedDepth(sampleCoord);
            idx++;
        }
    }

    // Find the depth that has the most similar neighbors (representing the largest object surface)
    float targetFocus = depths[4]; // Default to center sample of this point
    int maxCount = 0;

    for (int i = 0; i < 9; i++)
    {
        int count = 0;
        float d1 = depths[i];
        // Adaptive threshold that scales with depth
        float threshold = 0.01 + d1 * 0.04;
        
        for (int j = 0; j < 9; j++)
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
    return targetFocus;
}

// Compute Focus distance based on the dominant depth (largest object) inside the autofocus zone
void PS_Focus(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float2 focus : SV_Target)
{
    float2 currentFocusData = tex2D(samFocus, float2(0.5, 0.5)).rg;
    float currentFocus = currentFocusData.r;
    if (currentFocus <= 0.0) currentFocus = 1.0;

    // Define 5 DSLR AF point centers
    float2 points[5];
    points[0] = float2(0.5, 0.5); // Center
    points[1] = float2(0.5 - FocusPointOffset, 0.5); // Left
    points[2] = float2(0.5 + FocusPointOffset, 0.5); // Right
    points[3] = float2(0.5, 0.5 - FocusPointOffset * BUFFER_ASPECT_RATIO); // Top
    points[4] = float2(0.5, 0.5 + FocusPointOffset * BUFFER_ASPECT_RATIO); // Bottom

    float targetFocus = 1.0;
    int activeIdx = 0;

    if (FocusPointSelect == 0) // Auto 5-Point
    {
        float minDepth = 1.0;
        int bestIdx = 0;
        
        [unroll]
        for (int i = 0; i < 5; i++)
        {
            float d = GetPointFocusDepth(points[i]);
            // Focus on the closest object (closest has the lowest depth value)
            if (d < minDepth && d > 0.0)
            {
                minDepth = d;
                bestIdx = i;
            }
        }
        
        // If all points are at far plane/sky, default to center point depth
        if (minDepth >= 1.0)
        {
            targetFocus = GetPointFocusDepth(points[0]);
            activeIdx = 0;
        }
        else
        {
            targetFocus = minDepth;
            activeIdx = bestIdx;
        }
    }
    else // Manual selection
    {
        activeIdx = FocusPointSelect - 1;
        targetFocus = GetPointFocusDepth(points[activeIdx]);
    }

    // Smoothly interpolate focus
    float factor = saturate(FocusSpeed * (frame_time * 0.001));
    float finalFocus = lerp(currentFocus, targetFocus, factor);
    focus = float2(finalFocus, (float)activeIdx);
}

// Main DoF Blur Pass
void PS_DoF(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 color : SV_Target)
{
    float centerDepth = ReShade::GetLinearizedDepth(texcoord);
    float2 focusData = tex2D(samFocus, float2(0.5, 0.5)).rg;
    float focusDist = focusData.x;
    int activeIdx = (int)(focusData.y + 0.5);
    
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
        
        // Show DSLR AF points if enabled
        if (ShowFocusPoint)
        {
            float2 points[5];
            points[0] = float2(0.5, 0.5); // Center
            points[1] = float2(0.5 - FocusPointOffset, 0.5); // Left
            points[2] = float2(0.5 + FocusPointOffset, 0.5); // Right
            points[3] = float2(0.5, 0.5 - FocusPointOffset * BUFFER_ASPECT_RATIO); // Top
            points[4] = float2(0.5, 0.5 + FocusPointOffset * BUFFER_ASPECT_RATIO); // Bottom

            float boxSize = 0.012;
            float borderThickness = 0.0015;

            [unroll]
            for (int i = 0; i < 5; i++)
            {
                float2 dist = abs(texcoord - points[i]);
                dist.y /= BUFFER_ASPECT_RATIO;
                
                // Draw a hollow square
                if (max(dist.x, dist.y) < boxSize && min(abs(dist.x - boxSize), abs(dist.y - boxSize)) < borderThickness)
                {
                    color.rgb = (i == activeIdx) ? float3(0.0, 1.0, 0.2) : float3(0.4, 0.4, 0.4);
                }
                // Center dot
                else if (max(dist.x, dist.y) < 0.002)
                {
                    color.rgb = (i == activeIdx) ? float3(0.0, 1.0, 0.2) : float3(0.4, 0.4, 0.4);
                }
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
    
    // Show DSLR AF points if enabled
    if (ShowFocusPoint)
    {
        float2 points[5];
        points[0] = float2(0.5, 0.5); // Center
        points[1] = float2(0.5 - FocusPointOffset, 0.5); // Left
        points[2] = float2(0.5 + FocusPointOffset, 0.5); // Right
        points[3] = float2(0.5, 0.5 - FocusPointOffset * BUFFER_ASPECT_RATIO); // Top
        points[4] = float2(0.5, 0.5 + FocusPointOffset * BUFFER_ASPECT_RATIO); // Bottom

        float boxSize = 0.012;
        float borderThickness = 0.0015;

        [unroll]
        for (int i = 0; i < 5; i++)
        {
            float2 dist = abs(texcoord - points[i]);
            dist.y /= BUFFER_ASPECT_RATIO;
            
            // Draw a hollow square
            if (max(dist.x, dist.y) < boxSize && min(abs(dist.x - boxSize), abs(dist.y - boxSize)) < borderThickness)
            {
                color.rgb = (i == activeIdx) ? float3(0.0, 1.0, 0.2) : float3(0.4, 0.4, 0.4);
            }
            // Center dot
            else if (max(dist.x, dist.y) < 0.002)
            {
                color.rgb = (i == activeIdx) ? float3(0.0, 1.0, 0.2) : float3(0.4, 0.4, 0.4);
            }
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
