using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace VolumetricFog
{
    public class VolumetricFogFeature : ScriptableRendererFeature
    {
        public enum Quality
        {
            Performant,
            Medium,
            High,
            Ultra,
        }

        private sealed class Pass : ScriptableRenderPass
        {
            private Material material;

            public Pass(Material material)
            {
                this.material = material;

                renderPassEvent = RenderPassEvent.BeforeRenderingTransparents;

                ConfigureInput(ScriptableRenderPassInput.Depth);
            }

            public override void OnCameraSetup(CommandBuffer commandBuffer, ref RenderingData renderingData)
            {
                ResetTarget();
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
            {
                CommandBuffer commandBuffer = CommandBufferPool.Get();
                
                using (new ProfilingScope(commandBuffer, profilingSampler))
                {
                    CoreUtils.SetRenderTarget(commandBuffer, renderingData.cameraData.renderer.cameraColorTargetHandle);
                    commandBuffer.DrawProcedural(Matrix4x4.identity, material, 0, MeshTopology.Triangles, 3);
                }
                
                context.ExecuteCommandBuffer(commandBuffer);

                CommandBufferPool.Release(commandBuffer);
            }
        }

        [Header("Shader")]

        [SerializeField]
        private Shader shader;
        private Material material;
        private Pass pass; 
        
        [Header("Fog")]
        [SerializeField]
        [ColorUsage(false, true)]
        private Color fogColor = new Color(0.48f, 0.62f, 0.75f);
        [SerializeField]
        [Min(0.0f)]
        private float fogDensity = 0.012f;
        [SerializeField]
        private float fogBaseHeight = 0.0f;
        [SerializeField]
        [Min(0.0f)]
        private float fogFalloff = 0.08f;
        [SerializeField]
        [Min(0.0f)]
        private float fogMinDistance = 0.0f;
        [SerializeField]
        [Min(0.0f)]
        private float fogMaxDistance = 250.0f;
        
        [Header("Scattering")]
        [SerializeField]
        [ColorUsage(false, true)]
        private Color scatteringColor = new Color(1.0f, 0.84f, 0.62f);
        [SerializeField]
        [Min(0.0f)]
        private float scatteringIntensity = 0.35f;
        [SerializeField]
        [Range(minDirectionality, maxDirectionality)]
        private float directionality = 0.55f;
        private const float minDirectionality = 0.0f;
        private const float maxDirectionality = 0.95f;
        [SerializeField]
        [Range(0.0f, 1.0f)]
        private float shadowSampleNoiseFactor = 1.0f;

        [Header("Sky")]
        [SerializeField]
        [Range(0.0f, 1.0f)]
        private float skyInfluence = 0.5f;

        [Header("Quality")]
        [SerializeField]
        private Quality quality = Quality.Ultra;

        private static SortedDictionary<Quality, int> shadowSampleStepCounts = new()
        {
            { Quality.Performant, 0 },
            { Quality.Medium, 8 },
            { Quality.High, 16 },
            { Quality.Ultra, 32 },
        };

        public override void Create()
        {
            CoreUtils.Destroy(material);

            if (shader != null)
            {
                material = CoreUtils.CreateEngineMaterial(shader);
            }

            pass = new Pass(material);
        }

        public override void AddRenderPasses(ScriptableRenderer scriptableRenderer, ref RenderingData renderingData)
        {
            if (material == null)
                return;
            
            if (fogDensity <= 0.0f)
                return;

            material.SetColor("_FogColor", fogColor);
            material.SetVector
            (
                "_FogParameters",
                new Vector4
                (
                    Mathf.Max(0.0f, fogDensity),
                    fogBaseHeight,
                    Mathf.Max(0.0f, fogFalloff),
                    Mathf.Max(0.0f, fogMinDistance)
                )
            );

            material.SetColor("_ScatteringColor", scatteringColor);
            material.SetVector
            (
                "_ScatteringParameters",
                new Vector4
                (
                    Mathf.Max(1.0f, fogMaxDistance),
                    Mathf.Clamp(directionality, minDirectionality, maxDirectionality),
                    Mathf.Max(0.0f, scatteringIntensity),
                    Mathf.Clamp01(skyInfluence)
                )
            );
            
            material.SetInt("_ShadowSampleStepCount", shadowSampleStepCounts[quality]);
            material.SetFloat("_ShadowSampleNoiseFactor", shadowSampleNoiseFactor);
            CoreUtils.SetKeyword(material, "_FOG_SHADOWS", quality != Quality.Performant);
            
            scriptableRenderer.EnqueuePass(pass);
        }

        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);

            CoreUtils.Destroy(material);

            material = null;
        }
    }
}