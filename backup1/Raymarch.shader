Shader "PeerPlay/Raymarch"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        // No culling or depth
        Cull Off ZWrite Off ZTest Always
     
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0

            #include "UnityCG.cginc"
            #include "DistanceFunctions.cginc"

            sampler2D _MainTex;
            uniform float4x4 _CamFrustum, _CamToWorld;
            uniform float _maxDistance;
            
            uniform int _MaxIteration;
            uniform float _Accuracy;
            
            // Light
            uniform float3 _LightDir,_LightCol;
            uniform float _LightIntensity;

            uniform sampler2D _CameraDepthTexture;

            // Color
            uniform fixed4 _GroundColor;
            uniform fixed4 _SphereColor[8];
            uniform float _ColorIntensity;

            uniform float2 _ShadowDistance;
            uniform float _ShadowIntensity;
            uniform float _ShadowPenumbra;

            // SDF 
            uniform float4 _sphere;
            uniform float _sphereSmooth;
            uniform float _degreeRotate;

            // Reflection
            uniform int _ReflectionCount;
            uniform float _ReflectionIntensity;
            uniform float _EnvReflIntensity;
            uniform samplerCUBE _ReflectionCube;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
                float3 ray: TEXCOORD1; // 存储在插值器中，插值生成rd
            };
            
            v2f vert (appdata v)
            {
                v2f o;
                half index = v.vertex.z; // 利用索引读取顶点的rd
                v.vertex.z = 0; 

                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;

                o.ray = _CamFrustum[(int)index].xyz; // 利用索引读取顶点的rd
                o.ray /= abs(o.ray.z); // 确保z的绝对值为1
                o.ray = mul(_CamToWorld, o.ray);

                return o;
            }
            
            float3 RotateY(float3 v, float degree)
            {
                float rad = 0.0174532925 * degree;
                float cosY = cos(rad);
                float sinY = sin(rad);
                return float3(cosY * v.x - sinY * v.z , v.y , sinY * v.x + cosY * v.z);
            }
       

            float4 distanceField(float3 p)
            {
                // 计算距离和颜色值
                float4 ground = float4(_GroundColor.rgb,sdPlane(p,float4(0,1,0,0)));
                float4 sphere = float4(_SphereColor[0].rgb,sdSphere(p - _sphere.xyz, _sphere.w));
             
                for(int i=1; i<8; i++)
                {
                    float4 sphereAdd = float4(_SphereColor[i].rgb,sdSphere(RotateY(p, _degreeRotate * i)-_sphere.xyz,_sphere.w));
                    sphere = opUS(sphere, sphereAdd, _sphereSmooth);
                }
               
                return opUS(sphere,ground ,_sphereSmooth);
            }

            float3 getNormal(float3 p)
            {
                const float2 offset = float2(0.001, 0.0);
                // 梯度近似法线
                float3 n = float3(
                    distanceField(p + offset.xyy).w - distanceField(p - offset.xyy).w,
                    distanceField(p + offset.yxy).w - distanceField(p - offset.yxy).w,
                    distanceField(p + offset.yyx).w - distanceField(p - offset.yyx).w
                    );
                return normalize(n);
            }

            float hardShadow(float3 ro,float3 rd,float mint,float maxt)
            {
                for(float t = mint;t<maxt;)
                {
                    float h = distanceField(ro + rd * t).w;
                    if(h < 0.001)
                    {
                        return 0.0;
                    }
                    t += h;
                }
                return 1.0;
            }
            float softShadow(float3 ro,float3 rd,float mint,float maxt,float k)
            {
                float result = 1.0;
                for(float t = mint;t<maxt;)
                {
                    float h = distanceField(ro + rd * t).w;
                    if(h < 0.001)
                    {
                        return 0.0;
                    }
                    result = min(result , k*h/t);
                    t += h;
                }
                return result;
            }

            uniform float _AoStepSize,_AoIntensity;
            uniform int _AoIterations;

            float AmbientOcclusion(float3 p, float3 n)
            {
                float step = _AoStepSize;
                float ao = 0.0;
                float dist;
                for(int i = 1;i<= _AoIterations;i++)
                {
                    dist = step * i;
                    ao += max(0.0,(dist - distanceField(p + n * dist).w)/dist);
                }
                return (1.0 - ao * _AoIntensity);
            }

            float3 Shading(float3 p,float3 n,fixed3 c)
            {
                float3 result;
                //  Diffuse Color
                float3 col = c.rgb * _ColorIntensity;
                // Directional Light
                // dot(-_LightDir, n)*0.5 + 0.5 确保点积结果至少为 0.5
                float3 light = (_LightCol * dot(-_LightDir, n)*0.5 + 0.5) * _LightIntensity;
                float shadow = softShadow(p,-_LightDir,_ShadowDistance.x,_ShadowDistance.y,_ShadowPenumbra) * 0.5 + 0.5;
                shadow = max(0.0,pow(shadow,_ShadowIntensity));
                // Ambient Occlusion
                float ao = AmbientOcclusion(p, n);

                result = col * light * shadow * ao;
                return result;
            }

            bool raymarching(float3 ro,float3 rd,float depth,float maxDistance,int maxInterations,inout float3 p,inout fixed3 dColor)
            {
                bool hit;
                float t = 0;

                for(int i = 0;i< maxInterations; i++)
                {
                    if(t > maxDistance || t >= depth)
                    {
                        // 绘制环境
                        hit = false;
                        break;
                    }
                    p = ro + rd * t; 
                    float4 d = distanceField(p);
                    if(d.w < _Accuracy)
                    {
                        dColor = d.rgb;
                        hit = true;
                        break;
                    }
                    t += d.w;
                }
                return hit;
            }


            fixed4 frag(v2f i) : SV_Target
            {
                float depth = LinearEyeDepth(tex2D(_CameraDepthTexture,i.uv).r);
                depth *= length(i.ray);

                fixed3 col = tex2D(_MainTex , i.uv);
                float3 rayDirection = normalize(i.ray.xyz);
                float3 rayOrigin = _WorldSpaceCameraPos;
                fixed4 result;
                float3 hitPostion;
                fixed3 dColor;
                
                bool hit = raymarching(rayOrigin,rayDirection,depth,_maxDistance,_MaxIteration,hitPostion,dColor);
                if(hit)
                {
                    float3 n = getNormal(hitPostion);
                    float3 s = Shading(hitPostion,n,dColor);
                    result = fixed4(s,1);
                    result += fixed4(texCUBE(_ReflectionCube,n).rgb * _EnvReflIntensity *_ReflectionIntensity,0);
                    // Reflection
                    if(_ReflectionCount > 0)
                    {
                        rayDirection = normalize(reflect(rayDirection,n));
                        rayOrigin = hitPostion + (rayDirection * 0.01);
                        hit = raymarching(rayOrigin,rayDirection,_maxDistance,_maxDistance*0.5,_MaxIteration/2,hitPostion,dColor);
                        if(hit)
                        {
                            float3 n = getNormal(hitPostion);
                            float3 s = Shading(hitPostion,n,dColor);
                            result += fixed4(s * _ReflectionIntensity,0);
                            if(_ReflectionCount > 1)
                            {
                                rayDirection = normalize(reflect(rayDirection,n));
                                rayOrigin = hitPostion + (rayDirection * 0.01);
                                hit = raymarching(rayOrigin,rayDirection,_maxDistance,_maxDistance*0.25,_MaxIteration/4,hitPostion,dColor);
                                if(hit)
                                {
                                    float3 n = getNormal(hitPostion);
                                    float3 s = Shading(hitPostion,n,dColor);
                                    result += fixed4(s * _ReflectionIntensity * 0.5,0);
                                }
                            }
                        }
                    }
               }
                else
                {
                    result = fixed4(0,0,0,0);
                }

                return fixed4( col * (1-result.w) + result.xyz * result.w ,1.0);
            }
            ENDCG
        }
    }
}
