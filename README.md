# Auto-Agent / Mac Mini AI Orchestration Stack

## Overview

This project implements a self-improving AI agent orchestration stack designed for a Mac mini (M4, 16GB unified memory, 512GB SSD). The system leverages Hermes Agent from Nous Research as the core agent, with Claude API for inference, and includes capability servers for AppleScript/iMessage automation.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Docker Compose Stack                  │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │ Hermes Agent│  │  Postgres   │  │    Redis        │  │
│  │  (Agent)    │  │  (Memory)   │  │  (Cache)        │  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│              Capability Server (FastAPI)                  │
├─────────────────────────────────────────────────────────┤
│  - AppleScript Automation                                 │
│  - iMessage Automation                                    │
│  - System Control                                         │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│              Optional: OpenClaw Bridge                    │
├─────────────────────────────────────────────────────────┤
│  - Telegram Integration                                   │
│  - Discord Integration                                    │
└─────────────────────────────────────────────────────────┘
```

## Components

### 1. Hermes Agent
- **Source**: Nous Research
- **Role**: Core self-improving AI agent
- **Memory**: Uses Postgres for persistent memory storage
- **Cache**: Uses Redis for fast retrieval

### 2. Capability Server
- **Framework**: FastAPI
- **Purpose**: Exposes system automation capabilities
- **Integrations**: AppleScript, iMessage, System Control

### 3. Memory Stack
- **Postgres**: Persistent agent memory and conversation history
- **Redis**: Caching layer for performance optimization

### 4. OpenClaw (Optional)
- **Purpose**: Telegram/Discord bridge for the agent
- **Status**: Optional component for messaging integration

## Memory Management

The system is designed for a 16GB unified memory Mac mini:
- **Hermes Agent**: ~4GB (conservative allocation)
- **Postgres**: ~4GB
- **Redis**: ~2GB
- **Capability Server**: ~2GB
- **System Reserve**: ~4GB

This leaves sufficient headroom for macOS operations and user applications.

## Implementation Plan

### Phase 1: Infrastructure Setup
1. Configure Docker Compose for Postgres, Redis, and Hermes containers
2. Set up capability server with FastAPI
3. Configure environment variables for Claude API integration

### Phase 2: Agent Integration
1. Deploy Hermes Agent with appropriate memory configuration
2. Set up memory management strategies
3. Configure agent self-improvement parameters

### Phase 3: Automation Capabilities
1. Implement AppleScript automation endpoints
2. Set up iMessage automation
3. Add system control capabilities

### Phase 4: Optional Bridge
1. Implement OpenClaw for messaging integration
2. Configure Telegram/Discord webhooks

### Phase 5: Testing & Optimization
1. Verify memory usage stays within constraints
2. Test all automation capabilities
3. Optimize performance and latency

## Getting Started

1. Clone this repository
2. Review `Mac-Mini-Agent.md` for detailed architecture
3. Review `Arch-Agent.md` for agent-specific configuration
4. Run `docker-compose up -d` to start the stack
5. Access the capability server at `http://localhost:8000/docs`

## License

MIT License