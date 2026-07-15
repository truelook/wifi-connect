import React from 'react';
import logo from '../img/logo.svg';
import { Navbar, Provider, Container } from 'rendition';
import { NetworkInfoForm } from './NetworkInfoForm';
import { Notifications } from './Notifications';
import { createGlobalStyle } from 'styled-components';

const HEADER_BG = '#1a1538';
const ACCENT = '#6CBE45';

const GlobalStyle = createGlobalStyle`
	body {
		margin: 0;
		font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', 'Oxygen',
			'Ubuntu', 'Cantarell', 'Fira Sans', 'Droid Sans', 'Helvetica Neue',
			sans-serif;
		-webkit-font-smoothing: antialiased;
		-moz-osx-font-smoothing: grayscale;
		background: #f4f5f8;
		min-height: 100vh;
	}

	code {
		font-family: source-code-pro, Menlo, Monaco, Consolas, 'Courier New', monospace;
	}

	/* Phone captive-portal chrome covers the top of the page — keep content clear. */
	#root {
		min-height: 100vh;
	}
`;

export interface NetworkInfo {
	ssid?: string;
	identity?: string;
	passphrase?: string;
}

export interface Network {
	ssid: string;
	security: string;
}

const App = () => {
	const [attemptedConnect, setAttemptedConnect] = React.useState(false);
	const [isFetchingNetworks, setIsFetchingNetworks] = React.useState(true);
	const [error, setError] = React.useState('');
	const [availableNetworks, setAvailableNetworks] = React.useState<Network[]>(
		[],
	);

	React.useEffect(() => {
		fetch('/networks')
			.then((data) => {
				if (data.status !== 200) {
					throw new Error(data.statusText);
				}

				return data.json();
			})
			.then(setAvailableNetworks)
			.catch((e: Error) => {
				setError(`Failed to fetch available networks. ${e.message || e}`);
			})
			.finally(() => {
				setIsFetchingNetworks(false);
			});
	}, []);

	const onConnect = (data: NetworkInfo) => {
		setAttemptedConnect(true);
		setError('');

		fetch('/connect', {
			method: 'POST',
			body: JSON.stringify(data),
			headers: {
				'Content-Type': 'application/json',
			},
		})
			.then((resp) => {
				if (resp.status !== 200) {
					throw new Error(resp.statusText);
				}
			})
			.catch((e: Error) => {
				setError(`Failed to connect to the network. ${e.message || e}`);
			});
	};

	const onTryAgain = () => {
		setAttemptedConnect(false);
		setError('');
	};

	return (
		<Provider
			theme={
				{
					colors: {
						primary: {
							main: ACCENT,
							light: '#8fd16b',
							dark: '#42A240',
						},
					},
					header: {
						color: HEADER_BG,
					},
				} as any
			}
		>
			<GlobalStyle />
			{!attemptedConnect && (
				<Navbar
					color={HEADER_BG}
					brand={
						<img
							src={logo}
							style={{ height: 32, display: 'block' }}
							alt="TrueLook"
						/>
					}
				/>
			)}

			<Container>
				{attemptedConnect ? (
					<Notifications
						attemptedConnect={attemptedConnect}
						hasAvailableNetworks={
							isFetchingNetworks || availableNetworks.length > 0
						}
						error={error}
						onTryAgain={onTryAgain}
					/>
				) : (
					<>
						<Notifications
							attemptedConnect={false}
							hasAvailableNetworks={
								isFetchingNetworks || availableNetworks.length > 0
							}
							error={error}
							onTryAgain={onTryAgain}
						/>
						<NetworkInfoForm
							availableNetworks={availableNetworks}
							onSubmit={onConnect}
						/>
					</>
				)}
			</Container>
		</Provider>
	);
};

export default App;
