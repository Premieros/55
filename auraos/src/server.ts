import * as dotenv from 'dotenv';
import { createApp } from '@/app';
import { testDatabaseConnection, pool } from '@/config/database';
import { createServer } from 'http';
import { Server as SocketIOServer } from 'socket.io';
import { initializeEventBroadcaster } from '@/shared/socket/eventBroadcaster';
import { env } from '@/config/env';
import jwt from 'jsonwebtoken';
import { startJobs, stopJobs } from '@/shared/jobs/jobRunner';
import { initMonitoring } from '@/shared/monitoring/monitoring';

// Load environment variables
dotenv.config();

const PORT = parseInt(process.env.PORT || '3000', 10);
const JWT_ISSUER = 'auraos-core';

// Start server
async function startServer() {
  try {
    // Fail closed: AuraOS must never advertise a ready server without its DB.
    const dbConnected = await testDatabaseConnection();
    if (!dbConnected) {
      throw new Error('Database connection failed; refusing to start AuraOS');
    }

    // Initialise monitoring (Sentry if SENTRY_DSN is configured, else console)
    initMonitoring();

    const app = createApp();
    const httpServer = createServer(app);
    const allowedOrigins = env.CORS_ORIGIN.split(',').map((o) => o.trim()).filter(Boolean);
    const io = new SocketIOServer(httpServer, {
      cors: {
        origin: allowedOrigins,
        methods: ['GET', 'POST'],
        credentials: true,
      },
    });

    initializeEventBroadcaster(io);

    // ── Socket.io connection handler ──────────────────────────────────────────
    // Authenticates socket connections via JWT and manages restaurant-room
    // membership so that real-time event broadcasts reach the correct tenants.
    io.on('connection', (socket) => {
      const token: string | undefined = socket.handshake.auth?.token;

      // Public customers (no token) may subscribe only to a specific order room.
      if (!token) {
        socket.on('track_order', (data: { orderNumber: string }) => {
          if (data?.orderNumber && typeof data.orderNumber === 'string') {
            socket.join(`order:${data.orderNumber}`);
          }
        });
        socket.on('disconnect', () => { /* auto-leaves rooms */ });
        return;
      }

      try {
        const decoded = jwt.verify(token, env.JWT_SECRET, {
          algorithms: ['HS256'],
          issuer: JWT_ISSUER,
        }) as {
          id: string;
          email: string;
          role: string;
          restaurantId: string;
        };

        // Only allow a socket to join the restaurant encoded in its signed JWT.
        socket.on('join_restaurant', (data: { restaurantId: string }) => {
          if (data?.restaurantId && data.restaurantId === decoded.restaurantId) {
            socket.join(`restaurant:${decoded.restaurantId}`);
          }
        });

        socket.on('disconnect', () => {
          // socket.io automatically leaves all rooms on disconnect.
        });
      } catch {
        socket.disconnect(true);
      }
    });

    httpServer.listen(PORT, () => {
      console.log('\n╔═════════════════════════════════════════════╗');
      console.log('║       🚀 AuraOS Server Started              ║');
      console.log('╚═════════════════════════════════════════════╝\n');
      console.log(`Port: ${PORT}`);
      console.log(`Environment: ${process.env.NODE_ENV}`);
      console.log('Database: Connected ✅');
      console.log('\n✨ Server is ready to accept requests');
      console.log('\n📝 Available endpoints:');
      console.log('   GET  /api/v1/health');
      console.log('   GET  /api/v1/status');
      console.log('');
      console.log('   Authentication:');
      console.log('   POST /api/v1/auth/register');
      console.log('   POST /api/v1/auth/login');
      console.log('   POST /api/v1/auth/refresh');
      console.log('   GET  /api/v1/auth/me (requires token)');
      console.log('   POST /api/v1/auth/logout (requires token)');
      console.log('');
      console.log('   Restaurants:');
      console.log('   POST /api/v1/restaurants (admin only)');
      console.log('   GET  /api/v1/restaurants (admin only)');
      console.log('   GET  /api/v1/restaurants/me (authenticated)');
      console.log('   PUT  /api/v1/restaurants/me (admin only)');
      console.log('   GET  /api/v1/restaurants/me/stats (admin only)');
      console.log('   DELETE /api/v1/restaurants/me (admin only)');
      console.log('   GET  /api/v1/restaurants/:slug (public)');
      console.log('');
      console.log('   Tables:');
      console.log('   GET  /api/v1/tables (authenticated)');
      console.log('   GET  /api/v1/tables/stats (admin only)');
      console.log('   GET  /api/v1/tables/:id (authenticated)');
      console.log('   POST /api/v1/tables (admin only)');
      console.log('   PUT  /api/v1/tables/:id (admin only)');
      console.log('   DELETE /api/v1/tables/:id (admin only)');
      console.log('');
      console.log('   Menu:');
      console.log('   GET  /api/v1/menus (authenticated)');
      console.log('   GET  /api/v1/menus/stats (admin only)');
      console.log('   GET  /api/v1/menus/categories (authenticated)');
      console.log('   GET  /api/v1/menus/categories/:id (authenticated)');
      console.log('   POST /api/v1/menus/categories (admin only)');
      console.log('   PUT  /api/v1/menus/categories/:id (admin only)');
      console.log('   DELETE /api/v1/menus/categories/:id (admin only)');
      console.log('   GET  /api/v1/menus/items (authenticated)');
      console.log('   GET  /api/v1/menus/items/:id (authenticated)');
      console.log('   POST /api/v1/menus/items (admin only)');
      console.log('   PUT  /api/v1/menus/items/:id (admin only)');
      console.log('   DELETE /api/v1/menus/items/:id (admin only)');
      console.log('');
      console.log('   Orders:');
      console.log('   POST /api/v1/orders (authenticated)');
      console.log('   GET  /api/v1/orders (authenticated)');
      console.log('   GET  /api/v1/orders/stats (admin only)');
      console.log('   GET  /api/v1/orders/:id (authenticated)');
      console.log('   PUT  /api/v1/orders/:id (KITCHEN, ADMIN)');
      console.log('   DELETE /api/v1/orders/:id (admin only)');
      console.log('');
      startJobs();
    });
  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
}

startServer();

process.on('SIGTERM', () => {
  console.log('\n🛑 SIGTERM received, shutting down gracefully...');
  stopJobs();
  pool.end();
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('\n🛑 SIGINT received, shutting down gracefully...');
  stopJobs();
  pool.end();
  process.exit(0);
});

process.on('unhandledRejection', (reason, promise) => {
  console.error('❌ Unhandled Rejection at:', promise, 'reason:', reason);
});

process.on('uncaughtException', (error) => {
  console.error('❌ Uncaught Exception:', error);
  stopJobs();
  pool.end().finally(() => process.exit(1));
});
