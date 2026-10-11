Shader "VolumetricFog"
{
    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
        }
        Pass
        {
            Name "VolumetricFog"

            ZTest Always
            ZWrite Off
            
            Cull Off

            Blend One OneMinusSrcAlpha, Zero One

            HLSLPROGRAM
            #pragma target 3.5

            #pragma multi_compile_fragment _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile_local_fragment _ _FOG_SHADOWS

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            CBUFFER_START(UnityPerMaterial)
            half4 _FogColor;
            float4 _FogParameters;
            half4 _ScatteringColor;
            float4 _ScatteringParameters;
            int _ShadowSampleStepCount;
            float _ShadowSampleNoiseFactor;
            CBUFFER_END

            #pragma vertex VolumetricFogVertex
            #pragma fragment VolumetricFogFragment

            struct Attributes
            {
                uint vertexID : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 viewNearPointWS : TEXCOORD0;
                float3 viewRayWS : TEXCOORD1;
            };

            float ComputeOpticalDepth(float fogHeightWS0, float fogHeightWS1, float viewLengthWS)
            {
                float fogDensity = _FogParameters.x;
                float fogBaseHeightWS = _FogParameters.y;
                float fogFalloff = _FogParameters.z;

                float fogHeightRelative0 = fogHeightWS0 - fogBaseHeightWS;
                float fogHeightRelative1 = fogHeightWS1 - fogBaseHeightWS;

                float fogHeightRelativeLow = min(fogHeightRelative0, fogHeightRelative1);
                float fogHeightRelativeHigh = max(fogHeightRelative0, fogHeightRelative1);

                float fogHeightSpan = fogHeightRelativeHigh - fogHeightRelativeLow;
                float fogHeightSpanUpper = max(fogHeightRelativeHigh, 0) - max(fogHeightRelativeLow, 0);
                float fogHeightSpanUpperScaled = fogFalloff * fogHeightSpanUpper;

                float lowerFraction = (fogHeightRelativeHigh > 0.0) ? saturate(-fogHeightRelativeLow / max(fogHeightSpan, 1e-5)) : 1.0;
                float upperFraction = 1 - lowerFraction;

                float lowerViewLengthWS = viewLengthWS * lowerFraction;
                float upperViewLengthWS = viewLengthWS * upperFraction;

                float lowerFogAverageDensity = fogDensity;

                float upperFogFloorDensityFactor = exp(-fogFalloff * max(fogHeightRelativeLow, 0));
                float upperFogFloorDensityAverager = (fogHeightSpanUpperScaled < 0.01) ? (1 - fogHeightSpanUpperScaled * 0.5) + (fogHeightSpanUpperScaled * fogHeightSpanUpperScaled / 6)
                                                                                       : (1 - exp(-fogHeightSpanUpperScaled)) / fogHeightSpanUpperScaled;
                float upperFogFloorDensity = fogDensity * upperFogFloorDensityFactor;
                float upperFogAverageDensity = upperFogFloorDensity * upperFogFloorDensityAverager;

                return (lowerViewLengthWS * lowerFogAverageDensity) + (upperViewLengthWS * upperFogAverageDensity);
            }

            Varyings VolumetricFogVertex(Attributes input)
            {
                Varyings output;

                uint vertexID = input.vertexID;
                
                float2 fullScreenTriangleUV = GetFullScreenTriangleTexCoord(vertexID);
                float3 viewNearPointWS = ComputeWorldSpacePosition(fullScreenTriangleUV, UNITY_NEAR_CLIP_VALUE, UNITY_MATRIX_I_VP);
                float3 viewMiddlePointWS = ComputeWorldSpacePosition(fullScreenTriangleUV, 0.5, UNITY_MATRIX_I_VP);

                output.positionCS = GetFullScreenTriangleVertexPosition(vertexID);
                output.viewNearPointWS = viewNearPointWS;
                output.viewRayWS = viewMiddlePointWS - viewNearPointWS;

                return output;
            }
            
            half4 VolumetricFogFragment(Varyings input) : SV_Target
            {
                float2 screenSize = _ScaledScreenParams.xy;

                float2 positionSS = input.positionCS.xy;
                float2 normalizedPositionSS = positionSS / screenSize;

                float rawDepth = SampleSceneDepth(normalizedPositionSS);

            #if UNITY_REVERSED_Z
                bool sky = rawDepth <= 0.000001;
                float ndcDepth = rawDepth;
            #else
                bool sky = rawDepth >= 0.999999;
                float ndcDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, rawDepth);
            #endif

                float3 viewNearPointWS = input.viewNearPointWS;
                float3 viewRayWS = input.viewRayWS;
                float3 viewNormalWS = normalize(viewRayWS);

                float viewMaxDistanceWS = _ScatteringParameters.x;

                float viewEndDistanceWS = viewMaxDistanceWS;
                if (!sky)
                {
                    float3 positionWS = ComputeWorldSpacePosition(normalizedPositionSS, ndcDepth, UNITY_MATRIX_I_VP);
                    viewEndDistanceWS = max(0.0, min(viewMaxDistanceWS, dot(positionWS - viewNearPointWS, viewNormalWS)));
                }

                float viewStartDistanceWS = min(_FogParameters.w, viewEndDistanceWS);
                float viewLengthWS = viewEndDistanceWS - viewStartDistanceWS;

                float3 viewStartPointWS = viewNearPointWS + viewNormalWS * viewStartDistanceWS;
                float3 viewEndPointWS = viewStartPointWS + viewNormalWS * viewLengthWS;

                float fogOpticalDepth = ComputeOpticalDepth(viewStartPointWS.y, viewEndPointWS.y, viewLengthWS);
                float fogOpacity = 1 - exp(-fogOpticalDepth);

                Light sun = GetMainLight();

                float g = _ScatteringParameters.y;
                float cosine = clamp(dot(viewNormalWS, sun.direction), -1, 1);
                float denominator = max(1 + g * g - 2 * g * cosine, 0.001);
                float phase = (1 - g * g) * rsqrt(denominator) / denominator;

                float sunWeight = fogOpacity;
            #if defined(_FOG_SHADOWS)
                sunWeight = 0;

                int shadowSampleStepCount = _ShadowSampleStepCount;

                float shadowSampleStepLengthWS = viewLengthWS / shadowSampleStepCount;
                float shadowSampleNoiseFactor = _ShadowSampleNoiseFactor;
                float shadowSampleNoise = InterleavedGradientNoise(floor(positionSS), 0);

                float transmittance = 1;

                for (int i = 0; i < shadowSampleStepCount; ++i)
                {
                    float3 stepStartPointWS = viewStartPointWS + viewNormalWS * i * shadowSampleStepLengthWS;
                    float3 stepEndPointWS = stepStartPointWS + viewNormalWS * shadowSampleStepLengthWS;

                    float shadowSampleFraction = lerp(0.5, frac(shadowSampleNoise + i * 0.618033998875), shadowSampleNoiseFactor);
                    float3 shadowSamplePositionWS = lerp(stepStartPointWS, stepEndPointWS, shadowSampleFraction);

                    float stepFogOpacity = 1 - exp(-ComputeOpticalDepth(stepStartPointWS.y, stepEndPointWS.y, shadowSampleStepLengthWS));

                    half stepShadowWeight = MainLightRealtimeShadow(TransformWorldToShadowCoord(shadowSamplePositionWS));
                    stepShadowWeight = lerp(stepShadowWeight, 1.0, GetMainLightShadowFade(shadowSamplePositionWS));

                    sunWeight += transmittance * stepShadowWeight * stepFogOpacity;
                    transmittance *= 1 - stepFogOpacity;
                }
            #endif

                float3 fogColor = _FogColor;

                float3 scatteringColor = _ScatteringColor;
                float scatteringIntensity = _ScatteringParameters.z;
                float scatteringWeight = phase * sunWeight * scatteringIntensity;
               
                float skyInfluence = _ScatteringParameters.w;

                float transparency = sky ? _ScatteringParameters.w : 1;

                return half4(fogColor * fogOpacity + sun.color * scatteringColor * scatteringWeight, fogOpacity) * transparency;
            }
            ENDHLSL
        }
    }
    Fallback Off
}