# Cross-Chain Bridge Flow

How tokens move from Chain A to Chain B through a burn-and-mint bridge with off-chain attestation.

```mermaid
sequenceDiagram
    actor User
    participant Server

    box Chain A
        participant ERC20_A as ERC20 (Chain A)
        participant Burner as Burner (Chain A)
        participant OutBridge as Outbound Bridge (Chain A)
    end

    box Chain B
        participant InBridge as Inbound Bridge (Chain B)
        participant Minter as Minter (Chain B)
        participant ERC20_B as ERC20 (Chain B)
    end

    Note over User, OutBridge: 1. Approve tokens for burning

    User ->>+ ERC20_A: approve(burner, amount)
    ERC20_A -->>- User: tx confirmed

    Note over User, OutBridge: 2. Initiate cross-chain transfer

    User ->>+ Burner: sendTo(destChain, recipient, amount)
    Burner ->>+ ERC20_A: burnFrom(user, amount)
    ERC20_A -->>- Burner: burned
    Burner ->>+ OutBridge: sendMessage(destChain, recipient, amount)
    OutBridge -->>- Burner: MessageSent event emitted
    Burner -->>- User: tx confirmed

    Note over Server, OutBridge: 3. Server watches for bridge events

    OutBridge --) Server: MessageSent event
    activate Server
    Server ->> Server: generate attestation
    deactivate Server

    Note over User, Server: 4. User requests attestation

    User ->>+ Server: requestAttestation(msgHash)
    Server -->>- User: signed attestation

    Note over User, ERC20_B: 5. Deliver attested message on destination chain

    User ->>+ InBridge: recvMessage(message, attestation)
    InBridge ->>+ Minter: recvMintRequest(recipient, amount)
    Minter ->>+ ERC20_B: mintTo(recipient, amount)
    ERC20_B -->>- Minter: minted
    Minter -->>- InBridge: done
    InBridge -->>- User: tx confirmed
```

## Step-by-step summary

| Step | Actor | Action | Chain |
|------|-------|--------|-------|
| 1 | User | `approve()` the Burner to spend tokens | A |
| 2 | User | `sendTo()` on Burner, which burns tokens and sends a bridge message | A |
| 3 | Server | Watches `MessageSent` events, produces attestations | off-chain |
| 4 | User | Fetches the signed attestation from the Server | off-chain |
| 5 | User | `recvMessage()` on Inbound Bridge, which mints tokens via Minter | B |
