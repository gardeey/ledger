import Fastify from 'fastify';
import { withBudget } from './actual.js';
import { startAutoSync } from './autosync.js';
import { buildDashboard } from './dashboard.js';
import { registerPages } from './pages.js';
import { registerPairs } from './pairs.js';
import { registerRoutes } from './routes.js';
import { registerSettings } from './settings_routes.js';

const app = Fastify({ logger: true });

// Dev-only CORS so `flutter run -d chrome` can call the bridge; prod is same-origin.
if (process.env.DEV_CORS) {
  app.addHook('onRequest', async (req, reply) => {
    reply.header('access-control-allow-origin', '*');
    reply.header('access-control-allow-headers', '*');
    if (req.method === 'OPTIONS') return reply.code(204).send();
  });
}

app.get('/api/health', async () => ({ ok: true }));

app.get('/api/dashboard', (req) => withBudget((api) => buildDashboard(api, req.query)));

registerRoutes(app);
registerPages(app);
registerPairs(app);
registerSettings(app);

await app.listen({ host: '0.0.0.0', port: Number(process.env.PORT || 8080) });
startAutoSync(app.log);
