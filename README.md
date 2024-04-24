
# SingularityDAO bridge OFT contracts
These contracts implement 3 variants of layerzero OFT bridges:
1. OFT (where token & OFT are same contract)
2. ProxyOFT (where token exists external to OFT, but OFT does lock/unlock instead of mint/burn)
3. IndirectOFT (where token exists external to OFT which does mint/burn)

There are also variants OFTWithFee, ProxyOFTWithFee and IndirectOFTV2WithFee which allow to charge bridge fees.
The ProxyOFTWithFee also has a reverseMessage feature, enabling to reverse bridge transactions which failed (f.e. due to lack of liquidity in the bridge).

## Audit
Audited by Paladin
https://paladinsec.co/projects/singularitydao/