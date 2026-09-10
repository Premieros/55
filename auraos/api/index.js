'use strict';

// Vercel entrypoint: run the compiled AuraOS backend and attach Socket.IO to the
// same HTTP server so REST mutations and real-time broadcasts share one process.
const { createServer } = require('node:http');
const { Server: SocketIOServer } = require('socket.io');
const jwt = require('jsonwebtoken');
const { createApp } = require('../dist/app.js');
const { initializeEventBroadcaster } = require('../dist/shared/socket/eventBroadcaster.js');
const { env } = require('../dist/config/env.js');

const JWT_ISSUER = 'auraos-core';
const SOCKET_PATH = '/api/index/socket.io';

const app = createApp();
const httpServer = createServer(app);
const allowedOrigins = env.CORS_ORIGIN.split(',').map((origin) => origin.trim()).filter(Boolean);

const io = new SocketIOServer(httpServer, {
  path: SOCKET_PATH,
  cors: {
    origin: allowedOrigins,
    methods: ['GET', 'POST'],
    credentials: true,
  },
  transports: ['websocket'],
});

initializeEventBroadcaster(io);

io.on('connection', (socket) => {
  const token = socket.handshake.auth?.token;

  // Public customer tracking is intentionally limited to an order-specific room.
  if (!token) {
    socket.on('track_order', (data) => {
      if (data?.orderNumber && typeof data.orderNumber === 'string') {
        socket.join(`order:${data.orderNumber}`);
      }
    });
    return;
  }

  try {
    const decoded = jwt.verify(token, env.JWT_SECRET, {
      algorithms: ['HS256'],
      issuer: JWT_ISSUER,
    });

    socket.on('join_restaurant', (data) => {
      if (data?.restaurantId && data.restaurantId === decoded.restaurantId) {
        socket.join(`restaurant:${decoded.restaurantId}`);
      }
    });
  } catch {
    socket.disconnect(true);
  }
});

module.exports = httpServer;
